{-# LANGUAGE ImplicitParams, FlexibleContexts #-}

module TypeSpecOps() where

import Control.Monad.Error
import Data.List

import TSLUtil
import Pos
import TypeSpec
import Spec

validateTypeSpec :: (?spec::Spec, MonadError String me) => Ctx -> TypeSpec -> me ()

-- * Struct fields must have unique names and valid types
validateTypeSpec ctx (StructSpec _ fs) = do
    uniqNames fs
    mapM (\(t,_) -> validateTypeSpec ctx t) fs
    return ()

-- * enumerator names must be unique in the current scope
validateTypeSpec ctx (EnumSpec _ es) = do
    mapM (ctxUniqName ctx) es
    return ()

-- * user-defined type names refer to valid types
validateTypeSpec ctx (UserTypeSpec p n) = 
    if ctxCheckType ctx n == False
       then err p $ "Unknown type " ++ show n
       else return ()

validateTypeSpec ctx _ = return ()

--validateTypes :: (?spec::Spec, MonadError String me) => me ()
--validateTypes
