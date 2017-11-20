{-#LANGUAGE TemplateHaskell #-}
{-#LANGUAGE CPP #-}
{-#LANGUAGE RankNTypes #-}
{-#LANGUAGE FlexibleInstances #-}
module Database.YeshQL.Backend
where

import Language.Haskell.TH
import Language.Haskell.TH.Quote
#if MIN_VERSION_template_haskell(2,7,0)
import Language.Haskell.TH.Syntax (Quasi(qAddDependentFile))
#endif
import Database.YeshQL.Util
import Database.YeshQL.Parser
import Data.List

data YeshBackend =
  YeshBackend
    { ybNames :: ParsedQuery -> ([Name], [PatQ], String, TypeQ)
    , ybMkQueryBody :: ParsedQuery -> Q Exp
    }

data YeshImpl =
  YeshImpl
    { yiDecs :: Q [Dec]
    , yiExp :: Q Exp
    }

foldYeshImpls :: [YeshImpl] -> YeshImpl
foldYeshImpls [] =
  YeshImpl
    { yiDecs = return []
    , yiExp = return $ VarE 'return `AppE` TupE []
    }
foldYeshImpls xs =
  YeshImpl
    { yiDecs =
        foldl1' (++) <$>
          mapM yiDecs xs
    , yiExp = do
        foldl1 (\a b -> VarE '(>>) `AppE` a `AppE` b) <$>
          mapM yiExp xs
    }

class Yesh a where
  yeshWith :: YeshBackend -> a
  yesh1With :: YeshBackend -> a

class YeshFile a where
  yeshFileWith :: YeshBackend -> a
  yesh1FileWith :: YeshBackend -> a

instance Yesh (String -> Q Exp) where
  yeshWith backend =
    withParsedQueries $ \queries -> do
      yiExp $ yeshAllWith backend (Right queries)
  yesh1With backend =
    withParsedQuery $ \query -> do
      yiExp $ yeshAllWith backend (Left query)

instance Yesh (String -> Q [Dec]) where
  yeshWith backend =
    withParsedQueries $ \queries -> do
      yiDecs $ yeshAllWith backend (Right queries)
  yesh1With backend =
    withParsedQuery $ \query -> do
      yiDecs $ yeshAllWith backend (Left query)

instance Yesh QuasiQuoter where
  yeshWith backend =
    QuasiQuoter
      { quoteDec = yeshWith backend
      , quoteExp = yeshWith backend
      , quoteType = error "YeshQL does not generate types"
      , quotePat = error "YeshQL does not generate patterns"
      }
  yesh1With backend =
    QuasiQuoter
      { quoteDec = yesh1With backend
      , quoteExp = yesh1With backend
      , quoteType = error "YeshQL does not generate types"
      , quotePat = error "YeshQL does not generate patterns"
      }

instance YeshFile (String -> Q Exp) where
  yeshFileWith backend =
    withParsedQueriesFile $ \queries -> do
      yiExp $ yeshAllWith backend (Right queries)
  yesh1FileWith backend =
    withParsedQueryFile $ \query -> do
      yiExp $ yeshAllWith backend (Left query)

instance YeshFile (String -> Q [Dec]) where
  yeshFileWith backend =
    withParsedQueriesFile $ \queries -> do
      yiDecs $ yeshAllWith backend (Right queries)
  yesh1FileWith backend =
    withParsedQueryFile $ \query -> do
      yiDecs $ yeshAllWith backend (Left query)

instance YeshFile QuasiQuoter where
  yeshFileWith backend =
    QuasiQuoter
      { quoteDec = yeshFileWith backend
      , quoteExp = yeshFileWith backend
      , quoteType = error "YeshQL does not generate types"
      , quotePat = error "YeshQL does not generate patterns"
      }
  yesh1FileWith backend =
    QuasiQuoter
      { quoteDec = yesh1FileWith backend
      , quoteExp = yesh1FileWith backend
      , quoteType = error "YeshQL does not generate types"
      , quotePat = error "YeshQL does not generate patterns"
      }

yeshAllWith :: YeshBackend -> Either ParsedQuery [ParsedQuery] -> YeshImpl
yeshAllWith backend (Left query) =
  let (argNames, patterns, funName, queryType) = ybNames backend query
      bodyQ = ybMkQueryBody backend query
      expr = sigE
              (lamE patterns bodyQ)
              queryType
      decs = do
        sRun <- sigD (mkName . lcfirst $ funName)
                    queryType
        fRun <- funD (mkName . lcfirst $ funName)
                    [ clause
                        (map varP argNames)
                        (normalB bodyQ)
                        []
                    ]
        return [sRun, fRun]
  in
    YeshImpl
      { yiDecs = decs
      , yiExp = expr
      }
yeshAllWith backend (Right queries) =
  foldYeshImpls $ map (yeshAllWith backend . Left) queries