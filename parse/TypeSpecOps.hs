{-# LANGUAGE ImplicitParams, FlexibleContexts #-}

module TypeSpecOps(typ',
                   isInt, isBool, isPtr,
                   expandType,
                   eqType,
                   eqMType,
                   validateTypeSpec) where

import Control.Monad.Error
import Data.List
import qualified Data.Map as M
import qualified Data.Graph.Inductive.Graph as G
import qualified Data.Graph.Inductive.Tree as G

import TSLUtil
import Name
import Pos
import TypeSpec
import Template
import Spec
import Scope
import ExprOps

-- Flatten out all type references
flattenType :: (?spec::Spec, WithType a) => Scope -> a -> TypeSpec
flattenType s x = 
    case typ x of
         (StructSpec p fs)  -> StructSpec p $ map (\f -> Field {pos f, flattenType s f, name f}) fs
         (PtrSpec p t)      -> PtrSpec    p $ flattenType s t
         (ArraySpec p t l)  -> ArraySpec  p (flattenType s t) l
         (UserTypeSpec p n) -> let (d,scope') = scopeGetType ?scope n
                               in flattenType scope' d
         t                  -> t

typ' :: (?spec::Spec, WithType a) => Scope -> a -> TypeSpec
typ' s a = fst $ expandType s a

expandType :: (?spec::Spec, WithType a) => Scope -> a -> (TypeSpec, Scope)
expandType s x = case typ x of
                      (UserTypeSpec _ n) -> let (t,s') = scopeGetType s n
                                            in expandType s' t
                      t                  -> (t,s)

isInt :: (?spec::Spec, WithType a) => Scope -> a -> Bool
isInt s x = case typ' s x of
                 SIntSpec _ _ -> True
                 UIntSpec _ _ -> True
                 _            -> False

isBool :: (?spec::Spec, WithType a) => Scope -> a -> Bool
isBool s x = case typ' s x of
                  BoolSpec _ -> True
                  _          -> False

isPtr :: (?spec::Spec, WithType a) => Scope -> a -> Bool
isPtr s x = case typ' s x of
                 PtrSpec _ _ -> True
                 _           -> False


eqType :: (?spec::Spec) => (TypeSpec, Scope) -> (TypeSpec,Scope) -> Bool
eqType (BoolSpec _       , _)    (BoolSpec _       , _)    = True
eqType (SIntSpec _ i1    , _)    (SIntSpec _ i2    , _)    = i1 == i2
eqType (UIntSpec _ i1    , _)    (UIntSpec _ i2    , _)    = i1 == i2
eqType (StructSpec _ fs1 , c1)   (StructSpec _ fs2 , c2)   = (length fs1 == length fs2) &&
                                                             (and $ map (\(f1,f2) -> name f2 == name f2 && eqType (typ f1,c1) (typ f2,c2)) (zip fs1 fs2))
eqType (EnumSpec _ es1   , _)    (EnumSpec _ es2   , _)    = False
eqType (PtrSpec _ t1     , c1)   (PtrSpec _ t2     , c2)   = eqType (t1,c1) (t2,c2)
eqType (ArraySpec _ t1 l1, c1)   (ArraySpec _ t2 l2, c2)   = eqType (t1,c1) (t2,c2) && evalInt c1 l1 == evalInt c2 l2
eqType (UserTypeSpec _ n1, c1)   (UserTypeSpec _ n2, c2)   = let (d1,c1') = scopeGetType c1 n1
                                                                 (d2,c2') = scopeGetType c2 n2
                                                             in eqType (typ d1, c1') (typ d2, c2')
eqType (TemplateTypeSpec _ n1,_) (TemplateTypeSpec _ n2,_) = n1 == n2
eqType _                         _                         = False

eqMType :: (?spec::Spec) => (Maybe TypeSpec, Scope) -> (Maybe TypeSpec,Scope) -> Bool
eqMType (Nothing, _)  (Nothing, _)  = True
eqMType (Just t1, c1) (Just t2, c2) = eqType (t1, c1)(t2, c2)
eqMType _             _             = False

---------------------------------------------------------------------
-- Validate individual TypeSpec
---------------------------------------------------------------------

validateTypeSpec :: (?spec::Spec, MonadError String me) => Scope -> TypeSpec -> me ()

-- * Struct fields must have unique names and valid types
validateTypeSpec scope (StructSpec _ fs) = do
    uniqNames (\n -> "Field " ++ n ++ " declared multiple times ") fs
    mapM (validateTypeSpec scope . typ) fs
    return ()

-- * enumerator names must be unique in the current scope
validateTypeSpec scope (EnumSpec _ es) = do
    mapM (scopeUniqName scope . name) es
    return ()

-- * user-defined type names refer to valid types
validateTypeSpec scope (UserTypeSpec _ n) = do {scopeCheckType scope n; return ()}

validateTypeSpec scope _ = return ()

---------------------------------------------------------------------
-- Check that the graph of dependencies among TypeDecl's is acyclic
---------------------------------------------------------------------

type TDeclGraph = G.Gr StaticSym ()

tdeclDeps :: (?spec::Spec) => GStaticSym -> [GStaticSym]
tdeclDeps n = (\(t,c) -> typeDeps c (typ t)) $ scopeGetType ScopeTop n

typeDeps :: (?spec::Spec) => Scope -> TypeSpec -> [GStaticSym]
typeDeps c (StructSpec _ fs) = concat $ 
    map ((\t -> case t of
                     UserTypeSpec _ n -> [scopeGTypeName $ scopeGetType c n]
                     _                -> typeDeps c t) . typ)
        fs
typeDeps c (UserTypeSpec _ n) = [scopeGTypeName $ scopeGetType c n]
typeDeps _ _ = []


-- construct dependency graph
tdeclGraph :: (?spec::Spec) => TDeclGraph
tdeclGraph = 
    let tnames = map ((\n -> [n]) . name) (specType ?spec) ++ 
                 (concat $ map (\t -> map (\d -> [name t, name d]) $ tmTypeDecl t) $ specTemplate ?spec)
        tmap = M.fromList $ zip tnames [1..]
        gnodes = foldl' (\g (t,id) -> G.insNode (id, t) g) G.empty (M.toList tmap)
    in foldl' (\g n -> foldl' (\g d -> G.insEdge (tmap M.! n, tmap M.! d, ()) g) 
                              g (tdeclDeps n))
              gnodes tnames

validateTypeDecls :: (?spec::Spec, MonadError String me) => me ()
validateTypeDecls = 
    case grCycle tdeclGraph of
         Nothing -> return ()
         Just c  -> err (pos $ snd $ head c) $ "Cyclic type aggregation: " ++ (intercalate "->" $ map (show . snd) c)
