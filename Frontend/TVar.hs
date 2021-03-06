{-# LANGUAGE ImplicitParams, UndecidableInstances #-}

module Frontend.TVar(Var(Var,varMem,varInit,varTSpec,varName)) where

import Text.PrettyPrint

import Pos
import Name
import PP
import Frontend.Type
import Frontend.Expr

data Var = Var { vpos     :: Pos
               , varMem   :: Bool
               , varTSpec :: TypeSpec
               , varName  :: Ident
               , varInit  :: Maybe Expr}

instance PP Var where
    pp (Var _ m t n Nothing)  = (if m then text "mem" else empty) <+> pp t <+> pp n
    pp (Var _ m t n (Just i)) = (if m then text "mem" else empty) <+> pp t <+> pp n <+> char '=' <+> pp i

instance WithPos Var where
    pos       = vpos
    atPos v p = v{vpos = p}

instance WithName Var where
    name = varName

instance WithTypeSpec Var where
    tspec = varTSpec
