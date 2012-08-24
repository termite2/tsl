{-# LANGUAGE FlexibleContexts, ImplicitParams, TupleSections #-}

module TemplateOps(tmNamespace, 
                   tmParents) where

import Data.List
import Data.Maybe
import qualified Data.Set as S
import qualified Data.Map as M
import Control.Monad.Error
import qualified Data.Graph.Inductive.Graph as G
import qualified Data.Graph.Inductive.Tree as G
import Control.Applicative

import TSLUtil
import Pos
import Name
import TypeSpec
import Template
import Spec
import SpecOps
import NS

tmParents :: (?spec::Spec) => Template -> [Template]
tmParents t = map (getTemplate . drvTemplate) (tmDerive t)

-- Find port or instance by name.  Returns the name of the associated template.
tmLookupPortInst :: (MonadError String me) => Template -> Ident -> me Ident
tmLookupPortInst t n = case listToMaybe $ catMaybes [p, i] of
                            Nothing -> err (pos n) $ "Unknown port or instance name " ++ show n
                            Just tn -> return tn
    where p = fmap (portTemplate) $ find ((== n) . name) (tmPort t)
          i = fmap (instTemplate) $ find ((== n) . name) (tmInst t)

-- Validate derive statement or instance
-- * template name is valid
-- * correct number and types of parameters
validateDrvInst :: (?spec::Spec, MonadError String me) => Template -> Ident -> [Ident] -> Pos -> me ()
validateDrvInst tm tname ports posit = do
    checkTemplate tname
    let t = getTemplate tname 
    assert ((length $ tmPort t) == (length ports)) posit $ 
           "Incorrect number of parameters to template " ++ sname t ++ 
           ". " ++ (show $ length $ tmPort t) ++ " parameters required."
    mapM (\(p,n) -> do ptm <- tmLookupPortInst tm n
                       assert (portTemplate p == ptm) (pos n) $ 
                              "Invalid template parameter: expected template type: " ++ (show $ portTemplate p) ++ ", actual type: " ++ show ptm)
         (zip (tmPort t) ports)
    return ()


-----------------------------------------------------------
-- Validate template instances
-- * Every instance refers to a valid template and takes
--   correct number and types of arguments
-----------------------------------------------------------

-- Validate template instantiation statement
validateInstance :: (?spec::Spec, MonadError String me) => Template -> Instance -> me ()
validateInstance tm i = validateDrvInst tm (instTemplate i) (instPort i) (pos i)


-----------------------------------------------------------
-- Validate template port
-- * port refers to a valid template 
-----------------------------------------------------------

validatePort :: (?spec::Spec, MonadError String me) => Template -> Port -> me ()
validatePort tm p = do {checkTemplate $ portTemplate p; return ()}


-----------------------------------------------------------
-- Validate template derivation
-- 1. Validate each derive statement locally
-- 2. Validate the shape of the derivation graph (no cycles)
-----------------------------------------------------------

type DrvGraph = G.Gr Ident ()

-- construct template derivation graph
drvGraph :: (?spec::Spec) => DrvGraph
drvGraph = 
    let tmap = M.fromList $ zip (map name $ specTemplate ?spec) [1..]
        gnodes = foldl' (\g t -> G.insNode (tmap M.! name t, name t) g) G.empty (specTemplate ?spec)
    in foldl' (\g t -> foldl' (\g d -> G.insEdge (tmap M.! name t, tmap M.! drvTemplate d, ()) g) 
                              g (tmDerive t))
              gnodes (specTemplate ?spec)


-- Validate the derivation graph of a spec
-- * no circular derivations
validateDerives :: (?spec::Spec, MonadError String me) => me ()
validateDerives = 
    case grCycle drvGraph of
         Nothing -> return ()
         Just c  -> err (pos $ snd $ head c) $ "Template derivation cycle: " ++ (intercalate "->" $ map (show . snd) c) 


-- Validate individual derive statement
validateDerive :: (?spec::Spec, MonadError String me) => Template -> Derive -> me ()
validateDerive tm d = validateDrvInst tm (drvTemplate d) (drvPort d) (pos d)

------------------------------------------------------------------------------
-- Validate template namespace
-- 1. No identifier is declared twice in a template
-- 2. Template-level declarations don't conflict with specification-level
--    declarations
-- 2. Template does not derive the same identifier from multiple parents
------------------------------------------------------------------------------

tmLocalDecls :: (?spec::Spec) => Template -> [Obj]
tmLocalDecls t = (map (ObjPort t)                     (tmPort t))     ++
                 (map (ObjConst (ScopeTemplate t))    (tmConst t))    ++
                 (map (ObjTypeDecl (ScopeTemplate t)) (tmTypeDecl t)) ++
                 (map (ObjGVar t)                     (tmVar t))      ++
                 (map (ObjInstance t)                 (tmInst t))     ++
                 (map (ObjProcess t)                  (tmProcess t))  ++
                 (map (ObjMethod t)                   (tmMethod t))   ++
                 (concat $ map (\d -> case tspec d of
                                           EnumSpec _ es -> map (ObjEnum (tspec d, ScopeTemplate t)) es
                                           _             -> []) (tmTypeDecl t))


-- All objects declared in the template or inherited from parents
tmLocalAndParentDecls :: (?spec::Spec) => Template -> [Obj]
tmLocalAndParentDecls t = concat $ (tmLocalDecls t):parents
    where parents = map (tmLocalAndParentDecls . getTemplate . drvTemplate) (tmDerive t)

-- All identifiers visible as local names at the template level
tmNamespace :: (?spec::Spec) => Template -> [Obj]
tmNamespace t = specNamespace ++ tmLocalAndParentDecls t

-- * No identifier is declared twice in a template
-- * Template-level declarations don't conflict with specification-level
--   declarations
-- * No illegal overrides
validateTmNS :: (?spec::Spec, MonadError String me) => Template -> me ()
validateTmNS t = do
    let ns = tmLocalDecls t
    uniqNames (\n -> "Identifier " ++ n ++ " declared multiple times in template " ++ sname t) ns
    case mapMaybe (\o -> fmap (o,) $ find (\o' -> name o' == name o) specNamespace) ns of
         []       -> return ()
         (o,o'):_ -> err (pos o) $ "Identifier " ++ sname o ++ " conflicts with global declaration at " ++ spos o'
    checkTmOverrides t


-- * derived template-level namespaces do not overlap
validateTmDeriveNS :: (?spec::Spec, MonadError String me) => Scope -> Template -> me ()
validateTmDeriveNS c t = do
    let nss = map (\d -> map (d,) $ tmLocalAndParentDecls $ getTemplate $ drvTemplate d) (tmDerive t)
    foldM (\names ns -> case intersectBy (\o1 o2 -> (name $ snd o1) == (name $ snd o2)) names ns of
                             []      -> return $ names++ns
                             (d,o):_ -> err (pos d) $ "Template " ++ sname t ++ " derives mutiple declarations of identifier " ++ sname o ++ 
                                                      " from the following templates: " ++ 
                                                      (intercalate ", " $ map (show . drvTemplate . fst) $ filter ((==name o) . name . snd) (names++ns)))
          [] nss
    return ()

-- * only method and port names can be overloaded
checkTmOverrides :: (?spec::Spec, MonadError String me) => Template -> me ()
checkTmOverrides t = do
    let local = tmLocalDecls t
        enviro = specNamespace ++ (concat $ map (tmLocalAndParentDecls . getTemplate . drvTemplate) (tmDerive t))
        override = filter (\(o1,o2) -> name o1 == name o2) $ (,) <$> local <*> enviro
    mapM (\(o1,o2) -> case (o1,o2) of
                           (ObjMethod _ m1, ObjMethod _ m2) -> return ()
                           (ObjPort _ p1,   ObjPort _ p2)   -> return ()
                           _                                -> err (pos o1) $ "Identifier " ++ (sname o1) ++ " overrides previous declaration at " ++ spos o2)
         override
    return ()