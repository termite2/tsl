module Cascade(Cascade(..),
               casTree,
               casMap,
               FCascade,
               ECascade,
               BCascade,
               TCascade,
               fcasToFormula,
               fcasPrune) where

import Control.Applicative
import Data.List
import Text.PrettyPrint

import PP
import Util
import IExpr
import BFormula
import Predicate

-- Intermediate data structure that represents the value of
-- an arithmetic expression depending on pointer predicates
-- or other conditions
data Cascade a = CasTree  [(Formula, Cascade a)] 
               | CasLeaf a

casTree :: (PP a) => [(Formula, Cascade a)] -> Cascade a
casTree bs | null bs'   = error $ "casTree: invalid cascade " ++ show (CasTree bs)
           | otherwise  = CasTree bs'
    where bs' = filter ((/= FFalse) . fst) bs

-- Map leaves of a cascade to cascades
casMap :: (a -> Cascade b) -> Cascade a -> Cascade b
casMap f (CasLeaf x)  = f x
casMap f (CasTree bs) = CasTree $ map (mapSnd (casMap f)) bs

instance Functor Cascade where
    fmap f (CasLeaf l)  = CasLeaf $ f l
    fmap f (CasTree bs) = CasTree $ map (mapSnd (fmap f)) bs

-- TODO: prune inconsistent branches
instance Applicative Cascade where
    pure  x    = CasLeaf x
    (<*>) cf c = casMap (\f -> fmap f c) cf

instance (PP a) => PP (Cascade a) where
    pp (CasLeaf x)  = pp x
    pp (CasTree bs) = vcat $ map (\(f,c) -> pp f <> char ':' $$ (nest' $ pp c)) bs

instance (PP a) => Show (Cascade a) where
    show = render . pp

type FCascade = Cascade Formula
type BCascade = Cascade Bool
type ECascade = Cascade Expr
type TCascade = Cascade Term

fcasToFormula :: FCascade -> Formula
fcasToFormula (CasLeaf f)      = f
fcasToFormula (CasTree [])     = FFalse
fcasToFormula (CasTree (b:bs)) = foldl' (\f (c,cas) -> fdisj [f, fconj [c, fcasToFormula cas]]) 
                                        (fconj [fst b, fcasToFormula $ snd b]) bs

-- Recursively prune false leaves
fcasPrune :: FCascade -> FCascade
fcasPrune (CasLeaf f)  = CasLeaf f
fcasPrune (CasTree bs) = if null bs' then CasLeaf FFalse else casTree bs'
    where bs' = filter (\(_,cas) -> case cas of 
                                         CasLeaf FFalse -> False
                                         _              -> True)
                       $ map (mapSnd fcasPrune) bs
