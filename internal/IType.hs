module IType(Field(..),
             Type(..),
             Typed(..),
             typeWidth,
             typeSigned,
             isTypeInt,
             isTypeScalar,
             Enumeration(..)) where

import Text.PrettyPrint

import PP

data Field = Field String Type deriving (Eq)

instance PP Field where
    pp (Field n t) = pp t <+> text n

instance Typed Field where
    typ (Field _ t) = t

data Type = Bool
          | SInt     Int
          | UInt     Int
          | Enum     String
          | Struct   [Field]
          | Ptr      Type
          | Array    Type Int
          deriving (Eq)

instance PP Type where
    pp Bool        = text "bool"
    pp (SInt i)    = text "sint" <> char '<' <> pp i <> char '>'
    pp (UInt i)    = text "uint" <> char '<' <> pp i <> char '>'
    pp (Enum e)    = text e
    pp (Struct fs) = text "struct" <+> (braces $ nest' $ vcat $ map ((<> semi) . pp) fs)
    pp (Ptr t)     = pp t <> char '*'
    pp (Array t l) = pp t <> char '[' <> pp l <> char ']'

instance Show Type where
    show = render . pp

twidth :: Type -> Int
twidth (SInt w) = w
twidth (UInt w) = w
twidth _        = error "twidth undefined"

class Typed a where
    typ :: a -> Type

instance Typed Type where
    typ = id

typeWidth :: (Typed a) => a -> Int
typeWidth = twidth . typ

typeSigned :: (Typed a) => a -> Bool
typeSigned x = case typ x of
                    SInt _ -> True
                    UInt _ -> False


isTypeInt :: (Typed a) => a -> Bool
isTypeInt x = case typ x of
                   SInt _ -> True
                   UInt _ -> True
                   _      -> False

isTypeScalar :: (Typed a) => a -> Bool
isTypeScalar x = case typ x of
                      Bool   -> True
                      SInt   -> True
                      Enum _ -> True
                      Ptr _  -> True
                      _      -> False

data Enumeration = Enumeration { enumName  :: String
                               , enumEnums :: [String]
                               }

instance PP Enumeration where
    pp (Enumeration n es) = text "enum" <+> text n <+> 
                            (braces' $ vcat $ map ((<> semi) . text) es)
