{-# LANGUAGE ImplicitParams,UndecidableInstances #-}

module Method(TaskCat(..), 
              MethodCat(..), 
              ArgDir(..), 
              Arg, 
              Method(var, arg)) where

import Pos
import Name
import qualified NS
import qualified Var      as V
import qualified TypeSpec as T

data TaskCat = Controllable
             | Uncontrollable
             | Invisible

data MethodCat = Function
               | Procedure
               | Task TaskCat

data ArgDir = In
            | Out

-- Method argument
data Arg = Arg { apos  :: Pos
               , aname :: Ident
               , atyp  :: T.TypeSpec
               , dir   :: ArgDir}

instance WithName Arg where
    name = aname

instance WithPos Arg where
    pos = apos

instance T.WithType Arg where 
    typ = atyp

-- Method
data Method = Method { mpos   :: Pos
                     , mname  :: Ident
                     , cat    :: MethodCat
                     , rettyp :: T.TypeSpec
                     , arg    :: [Arg]
                     , var    :: [V.Var]}

instance WithName Method where
    name = mname

instance WithPos Method where
    pos = mpos

instance T.WithType Method where
    typ = rettyp
