{-#LANGUAGE TemplateHaskell #-}
{-#LANGUAGE CPP #-}
{-|
Module: Database.YeshQL
Description: Turn SQL queries into type-safe functions.
Copyright: (c) 2015 Tobias Dammers
Maintainer: Tobias Dammers <tdammers@gmail.com>
Stability: experimental
License: MIT

Unlike existing libraries such as Esqueleto or Persistent, YeshQL does not try
to provide full SQL abstraction with added type safety; instead, it gives you
some simple tools to write the SQL queries yourself and bind them to (typed)
functions.

= Usage

The main workhorses are the 'yesh1' (to define one query) and 'yesh' (to define
multiple queries) quasi-quoters.

Both 'yesh' and 'yesh1' can produce either declarations or expressions,
depending on the context in which they are used.

== Creating Declarations

When used at the top level, or inside a @where@ block, the 'yesh' and 'yesh1'
quasi-quoters will declare one or more functions, according to the query names
given in the query definition. Example:

@
[yesh1|
    -- name:insertUser :: (Integer)
    -- :name :: String
    INSERT INTO users (name) VALUES (:name) RETURNING id |]
@

...will create a top-level function of type:

@
    insertUser :: IConnection conn => conn -> String -> IO [Integer]
@

= Syntax

Because SQL itself does not *quite* provide enough information to generate a
fully typed Haskell function, we extend SQL syntax a bit.

Here's what a typical YeshQL definition looks like:

@
[yesh|
    -- name:insertUser :: (Integer)
    -- :name :: String
    INSERT INTO users (name) VALUES (:name) RETURNING id;
    -- name:deleteUser :: Integer
    -- :id :: Integer
    DELETE FROM users WHERE id = :id;
    -- name:getUser :: (Integer, String)
    -- :id :: Integer
    SELECT id, name FROM users WHERE id = :id;
    -- name:getUserEx :: (Integer, String)
    -- :id :: Integer
    -- :filename :: String
    SELECT id, name FROM users WHERE name = :filename OR id = :id;
    |]
@

On top of standard SQL syntax, YeshQL query definitions are preceded by some
extra information in order to generate well-typed HDBC queries. All that
information is written in SQL line comments (@-- ...@), such that a valid
YeshQL definition is also valid SQL by itself (with the exception of
parameters, which follow the pattern @:paramName@).

Let's break it down:

@
    -- name:insertUser :: (Integer)
@

This line tells YeshQL to generate an object called @insertUser@, which should
be a function of type @IConnection conn => conn -> {...} -> IO (Integer)@
(where the @{...}@ part depends on query parameters, see below).

The declared return type can be one of the following:

- '()'; the generated function will ignore any and all results from the query
  and always return '()'.
- An integer scalar, e.g. @Integer@ or @Int@; the generated function will
  return a row count from @INSERT@ / @UPDATE@ / ... statements, or 0 from
  @SELECT@ statements.
- A tuple, where all elements implement 'FromSql'; the function will return
  the result set from a @SELECT@ query as a list of tuples, or an empty list
  for other query types.
- A "one-tuple", i.e., a type in parentheses. The return value will be a list
  of scalars, containing the values from the first (or only) column in
  the result set. Note that, unlike Haskell, YeshQL does distinguish between
  @Type@ and @(Type)@: the former is a scalar type, while the latter is a
  one-tuple whose only element is of type @Type@.

@
    -- :paramName :: Type
@

Declares a Haskell type for a parameter. The parameter @:paramName@ can then
be referenced zero or more times in the query itself, and will appear in the
generated function signature in the order of declaration. So in the above
example, the last query definition:

@
    -- name:getUserEx :: (Integer, String)
    -- :id :: Integer
    -- :filename :: String
    SELECT id, name FROM users WHERE name = :filename OR id = :id;
@

...will produce the function:

@
getUserEx :: IConnection conn => conn -> Integer -> String -> IO [(Integer, String)]
getUserEx conn id filename =
    -- ... generated implementation left out
@

= Loading Queries From External Files

The 'yeshFile' and 'yesh1File' flavors take a file name instead of SQL
definition strings. Using these, you can put your SQL in external files rather
than clutter your code with long quasi-quotation blocks.

= Other Functions That YeshQL Generates

On top of the obvious query functions, a top-level YeshQL quasiquotation
introduces two more definitions per query: a 'String' variable prefixed
@describe-@, which contains the SQL query as passed to HDBC (similar to the
@DESCRIBE@ feature in some RDBMS systems), and another 'String' variable
prefixed @doc-@, which contains all the free-form comments that precede the SQL
query in the query definition.

So for example, this quasiquotation:

@
[yesh1|
    -- name:getUser :: (Integer, String)
    -- :userID :: Integer
    -- Gets one user by the "id" column.
    SELECT id, username FROM users WHERE id = :userID LIMIT 1 |]
@

...would produce the following three top-level definitions:

@
getUser :: IConnection conn => Integer -> conn -> [(Integer, String)]
getUser userID conn = ...

describeGetUser :: String
describeGetUser = \"SELECT id, username FROM users WHERE id = ? LIMIT 1\"

docGetUser :: String
docGetUser = \"Gets one user by the \\\"id\\\" column.\"
@

 -}
module Database.YeshQL
(
-- * Quasi-quoters that take strings
  yesh, yesh1
-- * Quasi-quoters that take filenames
, yeshFile, yesh1File
-- * Low-level generators in the 'Q' monad
, mkQueryDecs
, mkQueryExp
-- * Query parsers
, parseQuery
, parseQueries
-- * AST
, ParsedQuery (..)
)
where

import Language.Haskell.TH
import Language.Haskell.TH.Quote
#if MIN_VERSION_template_haskell(2,7,0)
import Language.Haskell.TH.Syntax (Quasi(qAddDependentFile))
#endif
import Data.List (isPrefixOf, foldl')
import Data.Maybe (catMaybes, fromMaybe)
import Database.HDBC (fromSql, toSql, run, ConnWrapper, IConnection, quickQuery')
import qualified Text.Parsec as P
import Data.Char (chr, ord, toUpper, toLower)
import Control.Applicative ( (<$>), (<*>) )
import System.FilePath (takeBaseName)
import Data.Char (isAlpha, isAlphaNum)

import Database.YeshQL.Parser

nthIdent :: Int -> String
nthIdent i
    | i < 26 = [chr (ord 'a' + i)]
    | otherwise = let (j, k) = divMod i 26
                    in nthIdent j ++ nthIdent k

-- | Generate a top-level declaration or an expression for a single SQL query.
-- If used at the top level (i.e., generating a declaration), the query
-- definition must specify a query name.
yesh1 :: QuasiQuoter
yesh1 = QuasiQuoter
        { quoteDec = withParsedQuery mkQueryDecs
        , quoteExp = withParsedQuery mkQueryExp
        , quoteType = error "yesh1 does not generate types"
        , quotePat = error "yesh1 does not generate patterns"
        }

-- | Generate top-level declarations or expressions for several SQL queries.
-- If used at the top level (i.e., generating declarations), all queries in the
-- definitions must be named, and 'yesh' will generate a separate set of
-- functions for each.
-- If used in an expression context, the current behavior is somewhat
-- undesirable, namely sequencing the queries using '>>'.
--
-- Future versions will most likely change this to create a tuple of query
-- expressions instead, such that you can write something like:
--
-- @
-- let (createUser, getUser, updateUser, deleteUser) = [yesh|
--      -- name:createUser :: (Integer)
--      -- :username :: String
--      INSERT INTO users (username) VALUES (:username) RETURNING id;
--      -- name:getUser :: (Integer, String)
--      -- :userID :: Integer
--      SELECT id, username FROM users WHERE id = :userID;
--      -- name:updateUser :: Integer
--      -- :userID :: Integer
--      -- :username :: String
--      UPDATE users SET username = :username WHERE id = :userID;
--      -- name:deleteUser :: Integer
--      -- :userID :: Integer
--      DELETE FROM users WHERE id = :userID LIMIT 1;
--  |]
-- @
yesh :: QuasiQuoter
yesh = QuasiQuoter
        { quoteDec = withParsedQueries mkQueryDecsMulti
        , quoteExp = withParsedQueries mkQueryExpMulti
        , quoteType = error "yesh does not generate types"
        , quotePat = error "yesh does not generate patterns"
        }

-- | Generate one query definition or expression from an external file.
-- In a declaration context, the query name will be derived from the filename
-- unless the query contains an explicit name. Query name derivation works as
-- follows:
--
-- - Take only the basename (stripping off the directories and extension)
-- - Remove all non-alphabetic characters from the beginning of the name
-- - Remove all non-alphanumeric characters from the name
-- - Lower-case the first character.
--
-- Note that since there is always a filename to derive the query name from,
-- explicitly defining a query name is only necessary when you want it to
-- differ from the filename; however, making it explicit anyway is probably a
-- good idea.
yesh1File :: QuasiQuoter
yesh1File = QuasiQuoter
            { quoteDec = withParsedQueryFile mkQueryDecs
            , quoteExp = withParsedQueryFile mkQueryExp
            , quoteType = error "yesh1File does not generate types"
            , quotePat = error "yesh1File does not generate patterns"
            }

-- | Generate multiple query definitions or expressions from an external file.
-- Query name derivation works exactly like for 'yesh1File', except that an
-- underscore and a 0-based query index are appended to disambiguate queries
-- from the same file.
--
-- In an expression context, the same caveats apply as for 'yesh', i.e., to
-- generate expressions, you will almost certainly want 'yesh1File', not
-- 'yeshFile'.
yeshFile :: QuasiQuoter
yeshFile = QuasiQuoter
            { quoteDec = withParsedQueriesFile mkQueryDecsMulti
            , quoteExp = withParsedQueriesFile mkQueryExpMulti
            , quoteType = error "yeshFile does not generate types"
            , quotePat = error "yeshFile does not generate patterns"
            }

queryName :: String -> String -> Name
queryName prefix = mkName . queryIdentifier prefix

queryIdentifier :: String -> String -> String
queryIdentifier "" basename =
    lcfirst . makeValidIdentifier . takeBaseName $ basename
queryIdentifier prefix basename =
    (prefix ++) . ucfirst . makeValidIdentifier . takeBaseName $ basename

ucfirst :: String -> String
ucfirst "" = ""
ucfirst (x:xs) = toUpper x:xs

lcfirst :: String -> String
lcfirst "" = ""
lcfirst (x:xs) = toLower x:xs

withParsedQuery :: (ParsedQuery -> Q a) -> String -> Q a
withParsedQuery = withParsed parseQuery

withParsedQueries :: ([ParsedQuery] -> Q a) -> String -> Q a
withParsedQueries = withParsed parseQueries

withParsedQueryFile :: (ParsedQuery -> Q a) -> FilePath -> Q a
withParsedQueryFile p fn =
    withParsedFile
        (parseQueryN fn)
        (p . nameQuery (queryIdentifier "" fn))
        fn

withParsedQueriesFile :: ([ParsedQuery] -> Q a) -> FilePath -> Q a
withParsedQueriesFile p fn =
    withParsedFile
        (parseQueriesN fn)
        (p . nameQueries (queryIdentifier "" fn))
        fn

nameQuery :: String -> ParsedQuery -> ParsedQuery
nameQuery qname pq
    | null (pqQueryName pq) = pq { pqQueryName = qname }
    | otherwise = pq

nameQueries :: String -> [ParsedQuery] -> [ParsedQuery]
nameQueries basename queries =
    zipWith nameQuery queryNames queries
    where
        queryNames = [ basename ++ "_" ++ show i | i <- [0..] ]

makeValidIdentifier :: String -> String
makeValidIdentifier =
    filter isAlphaNum .
    dropWhile (not . isAlpha)

withParsed :: (Monad m, Show e) => (s -> Either e a) -> (a -> m b) -> s -> m b
withParsed p a src = do
    let parseResult = p src
    arg <- case parseResult of
                Left e -> fail . show $ e
                Right x -> return x
    a arg

-- | Monad in which we can perform IO and tag dependencies. Mostly needed
-- because we cannot easily make a 'MonadIO' instance for 'Q', and also
-- because we want to avoid a dependency on mtl or transformers. For
-- convenience, we also pull 'addDependentFile' into this typeclass.
class MonadPerformIO m where
    performIO :: IO a -> m a
    addDependentFile :: FilePath -> m ()

instance MonadPerformIO IO where
    performIO = id
    -- in IO, don't try to track dependencies
    addDependentFile = const $ return ()

instance MonadPerformIO Q where
    performIO = runIO
#if MIN_VERSION_template_haskell(2,7,0)
    -- modern GHC: proper implementation
    addDependentFile = qAddDependentFile
#else
    -- ancient GHC: ignore dependency
    addDependentFile = const $ return ()
#endif

withParsedFile :: (MonadPerformIO m, Monad m, Show e) => (String -> Either e a) -> (a -> m b) -> FilePath -> m b
withParsedFile p a filename =
    addDependentFile filename >>
    performIO (readFile filename) >>=
        withParsed p a

pgQueryType :: ParsedQuery -> TypeQ
pgQueryType query =
    [t|IConnection conn =>
        $(foldr
            (\a b -> [t| $a -> $b |])
            [t| conn -> IO $(returnType) |]
          $ argTypes)
      |]
    where
        argTypes = map (mkType . fromMaybe AutoType . pqTypeFor query) (pqParamNames query)
        returnType = case pqReturnType query of
                        Left tn -> mkType tn
                        Right [] -> tupleT 0
                        Right (x:[]) -> appT listT $ mkType x
                        Right xs -> appT listT $ foldl' appT (tupleT $ length xs) (map mkType xs)

mkType :: ParsedType -> Q Type
mkType (MaybeType n) = [t|Maybe $(conT . mkName $ n)|]
mkType (PlainType n) = conT . mkName $ n
mkType AutoType = [t|String|]

mkQueryDecsMulti :: [ParsedQuery] -> Q [Dec]
mkQueryDecsMulti queries = concat <$> mapM mkQueryDecs queries

-- TODO: instead of sequencing the queries, put them in a tuple.
mkQueryExpMulti :: [ParsedQuery] -> Q Exp
mkQueryExpMulti queries =
    foldl1 (\a b -> VarE '(>>) `AppE` a `AppE` b) <$> mapM mkQueryExp queries

pqNames :: ParsedQuery -> ([Name], [PatQ], String, TypeQ)
pqNames query =
    let argNamesStr = pqParamNames query ++ ["conn"]
        argNames = map mkName argNamesStr
        patterns = map varP argNames
        funName = pqQueryName query
        queryType = pgQueryType query
    in (argNames, patterns, funName, queryType)

mkQueryDecs :: ParsedQuery -> Q [Dec]
mkQueryDecs query = do
    let (argNames, patterns, funName, queryType) = pqNames query
    sRun <- sigD (mkName . lcfirst $ funName) queryType
    fRun <- funD (mkName . lcfirst $ funName)
                [ clause
                    (map varP argNames)
                    (normalB . mkQueryBody $ query)
                    []
                ]
    sDescribe <- sigD (queryName "describe" funName) [t|String|]
    fDescribe <- funD (queryName "describe" funName)
                    [ clause
                        []
                        (normalB . litE . stringL . pqQueryString $ query)
                        []
                    ]
    sDocument <- sigD (queryName "doc" funName) [t|String|]
    fDocument <- funD (queryName "doc" funName)
                    [ clause
                        []
                        (normalB . litE . stringL . pqDocComment $ query)
                        []
                    ]
    return [sRun, fRun, sDescribe, fDescribe, sDocument, fDocument]

mkQueryExp :: ParsedQuery -> Q Exp
mkQueryExp query = do
    let (argNames, patterns, funName, queryType) = pqNames query
    sigE
        (lamE patterns (mkQueryBody query))
        queryType

mkQueryBody :: ParsedQuery -> Q Exp
mkQueryBody query = do
    let (argNames, patterns, funName, queryType) = pqNames query

        convert :: ExpQ
        convert = case pqReturnType query of
                    Left tn -> varE 'fromInteger
                    Right [] -> [|\_ -> ()|]
                    Right (x:[]) -> [|map (fromSql . head)|]
                    Right xs ->
                        let varNames = map nthIdent [0..pred (length xs)]
                        in [|map $(lamE
                                    -- \[a,b,c,...] ->
                                    [(listP (map (varP . mkName) varNames))]
                                    -- (fromSql a, fromSql b, fromSql c, ...)
                                    (tupE $ (map (\n -> appE (varE 'fromSql) (varE . mkName $ n)) varNames)))|]
        queryFunc = case pqReturnType query of
                        Left _ -> [| \qstr params conn -> $convert <$> run conn qstr params |]
                        Right _ -> [| \qstr params conn -> $convert <$> quickQuery' conn qstr params |]
    queryFunc
        `appE` (litE . stringL . pqQueryString $ query)
        `appE` (listE [ appE (varE 'toSql) (varE . mkName $ n) | (n, t) <- (pqParamsRaw query) ])
        `appE` (varE . mkName $ "conn")
