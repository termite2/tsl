{-# LANGUAGE ImplicitParams #-}

module Internal.TranSpec(Goal(..),
                FairRegion(..),
                Transition(..),
                TranSpec(..)) where

import Text.PrettyPrint

import PP
import Internal.IExpr
import Internal.CFA

data Transition = Transition { tranFrom :: Loc
                             , tranTo   :: Loc
                             , tranCFA  :: CFA
                             }

instance PP Transition where
    pp (Transition from to cfa) = text "transition" <+> 
                                  (braces' $ text "init:" <+> pp from
                                             $+$
                                             text "final:" <+> pp to
                                             $+$
                                             pp cfa)

instance Show Transition where
    show = render . pp

data Goal = Goal { goalName :: String
                 , goalCond :: Transition
                 }

instance PP Goal where
    pp (Goal n c) = text "goal" <+> pp n <+> char '=' <+> pp c

data FairRegion = FairRegion { fairName :: String
                             , fairCond :: Expr
                             }

instance PP FairRegion where
    pp (FairRegion n c) = text "fair" <+> pp n <+> char '=' <+> pp c

data TranSpec = TranSpec { tsCTran  :: [Transition]
                         , tsUTran  :: [Transition]
                         , tsInit   :: (Transition, Expr) -- initial state constraint (constraint_on_spec_variables,constraints_on_aux_variables)
                         , tsGoal   :: [Goal] 
                         , tsFair   :: [FairRegion]       -- sets of states f s.t. GF(-f)
                         }

instance PP TranSpec where
    pp s = (vcat $ map (($+$ text "") . pp) (tsCTran s))
           $+$
           (vcat $ map (($+$ text "") . pp) (tsUTran s))
           $+$
           (text "init: " <+> (pp $ fst $ tsInit s))
           $+$
           (text "aux_init: " <+> (pp $ snd $ tsInit s))
           $+$
           (vcat $ map (($+$ text "") . pp) (tsGoal s))
           $+$
           (vcat $ map (($+$ text "") . pp) (tsFair s))
