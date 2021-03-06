{-# LANGUAGE ImplicitParams #-}

module Abstract.BFormula(BoolBOp(..),
                Formula(..),
                fbinop,
                fdisj,
                fconj,
                fnot,
                fVar,
                fAbsVars,
                formToExpr,
                bopToBoolOp,
                boolOpToBOp,
                avarAsnToFormula,
                ptrFreeBExprToFormula,
                fRel) where

import Data.List
import Data.Maybe
import Debug.Trace

import Util hiding (trace)
import Abstract.BFormulaTypes
import Abstract.Predicate
import {-# SOURCE #-} Abstract.MkPredicate
import Ops
import Internal.IVar
import Internal.ISpec
import Internal.IExpr
import Internal.IType
import {-# SOURCE #-} Solver.BVSMT


--------------------------------------------------
-- Constants
--------------------------------------------------

-- Don't abstract a variable if it is maxAVarIntWidth wide or less
maxAVarIntWidth = 1

-- effectively disables predicate abstraction
--maxAVarIntWidth = 64



fbinop :: BoolBOp -> Formula -> Formula -> Formula
fbinop Conj f1 f2 = fconj [f1,f2]
fbinop Disj f1 f2 = fdisj [f1,f2]
fbinop op   f1 f2 = FBinOp op f1 f2


fdisj :: [Formula] -> Formula
fdisj fs = case disjuncts'' of 
                [disjunct] -> disjunct
                _          -> foldl' (FBinOp Disj) (head disjuncts'') (tail disjuncts'')
    where disjuncts = filter (/= FFalse) fs
          disjuncts' = if (any (== FTrue) disjuncts) then [FTrue] else disjuncts
          disjuncts'' = case disjuncts' of 
                             [] -> [FFalse] 
                             _  -> disjuncts'

fconj :: [Formula] -> Formula
fconj fs = case conjuncts'' of
                [conjunct] -> conjunct
                _          -> foldl' (FBinOp Conj) (head conjuncts'') (tail conjuncts'')
    where conjuncts = filter (/= FTrue) fs
          conjuncts' = if (any (== FFalse) conjuncts) then [FFalse] else conjuncts
          conjuncts'' = case conjuncts' of 
                             [] -> [FTrue] 
                             _  -> conjuncts'

fnot :: Formula -> Formula
fnot FTrue  = FFalse
fnot FFalse = FTrue
fnot f      = FNot f

avarAsnToFormula :: AbsVar -> Integer -> Formula
avarAsnToFormula v@(AVarPred _) 0 = fnot $ FBoolAVar v
avarAsnToFormula v@(AVarPred _) 1 = FBoolAVar v
avarAsnToFormula v@(AVarBool _) 0 = fnot $ FBoolAVar v
avarAsnToFormula v@(AVarBool _) 1 = FBoolAVar v
avarAsnToFormula v@(AVarEnum _) n = FEqConst v $ fromInteger n
avarAsnToFormula v@(AVarInt _)  n = FEqConst v $ fromInteger n

-- Convert boolean expression without pointers to a formula --

ptrFreeBExprToFormula :: (?spec::Spec) => Expr -> Formula
ptrFreeBExprToFormula e@(EVar _)                         = FBoolAVar $ AVarBool $ scalarExprToTerm e
ptrFreeBExprToFormula e@(EField _ _)                     = FBoolAVar $ AVarBool $ scalarExprToTerm e
ptrFreeBExprToFormula e@(EIndex _ _)                     = FBoolAVar $ AVarBool $ scalarExprToTerm e
ptrFreeBExprToFormula   (EConst (BoolVal True))          = FTrue
ptrFreeBExprToFormula   (EConst (BoolVal False))         = FFalse
ptrFreeBExprToFormula   (EUnOp Not e)                    = fnot $ ptrFreeBExprToFormula e
ptrFreeBExprToFormula   (EBinOp op e1 e2) | isRelBOp op  = fRel (bopToRelOp op) e1 e2
ptrFreeBExprToFormula   (EBinOp op e1 e2) | isBoolBOp op = FBinOp (bopToBoolOp op) (ptrFreeBExprToFormula e1) (ptrFreeBExprToFormula e2)
ptrFreeBExprToFormula   (ERel n as)                      = FBoolAVar $ AVarPred $ mkPRel n as
ptrFreeBExprToFormula e                                  = error $ "ptrFreeBExprToFormula " ++ show e

fRel :: (?spec::Spec) => RelOp -> Expr -> Expr -> Formula
-- type-independent cases
fRel op   e1 e2 | isConstExpr e1 && isConstExpr e2 = if (evalConstExpr $ EBinOp (relOpToBOp op) e1 e2) == BoolVal True then FTrue else FFalse
                | isConstExpr e1                   = fRel (relOpSwap op) e2 e1
fRel REq  e1 e2 | e1 == e2                         = FTrue
fRel RNeq e1 e2                                    = fnot $ fRel REq e1 e2
-- pointers
fRel REq  (EUnOp AddrOf e1) (EUnOp AddrOf e2)      = fRelAddrOf e1 e2
fRel REq  e1 e2 | (isPtr $ exprType e1)            = bvRelNormalise REq (PTPtr $ scalarExprToTerm e1) (PTPtr $ scalarExprToTerm e2)
-- bools
fRel REq  e1 e2 | (isBool $ exprType e1)           = FBinOp Equiv (ptrFreeBExprToFormula e1) (ptrFreeBExprToFormula e2)
-- enums
fRel REq  e1 e2 | (isEnum $ exprType e1) && isConstExpr e2 = FEqConst (AVarEnum $ scalarExprToTerm e1) (enumToInt en) where EnumVal en = evalConstExpr e2
fRel REq  e1 e2 | (isEnum $ exprType e1)           = FEq      (AVarEnum $ scalarExprToTerm e1) (AVarEnum $ scalarExprToTerm e2)
-- ints
fRel op   e1 e2 | (isInt $ exprType e1) && op == REq = fRelIntEq (e1, e2)
                | (isInt $ exprType e1)            = bvRelNormalise op (PTInt $ scalarExprToTerm e1) (PTInt $ scalarExprToTerm e2)


-- Two addrof expressions are equal if they are isomorphic and
-- array indices in matching positions in these expressions are equal.
fRelAddrOf :: (?spec::Spec) => Expr -> Expr -> Formula
fRelAddrOf (EVar n1)      (EVar n2)      | n1 == n2 = FTrue
fRelAddrOf (EVar n1)      (EVar n2)      | n1 /= n2 = FFalse
fRelAddrOf (EField e1 f1) (EField e2 f2) | f1 == f2 = fRelAddrOf e1 e2
                                         | f1 /= f2 = FFalse
fRelAddrOf (EIndex a1 i1) (EIndex a2 i2)            = fconj [fRelAddrOf a1 a2, fRel REq i1 i2]
fRelAddrOf (ESlice e1 s1) (ESlice e2 s2) | s1 == s2 = fRelAddrOf e1 e2
                                         | s1 /= s2 = FFalse
fRelAddrOf _              _                         = FFalse

-- Slice int expressions into the smallest common ranges.
fRelIntEq :: (?spec::Spec) => (Expr, Expr) -> Formula
fRelIntEq (e1,e2) = fRelIntEq' (exprPad w e1, exprPad w e2)
    where w = max (exprWidth e1) (exprWidth e2)

fRelIntEq' :: (?spec::Spec) => (Expr, Expr) -> Formula
fRelIntEq' (e1,e2) = fconj $ (fRelIntEq1 (e1',e2')):(maybe [] (return . fRelIntEq') mrest)
    where ((e1', e2'), mrest) = shortestPrefix e1 e2

shortestPrefix :: (?spec::Spec) => Expr -> Expr -> ((Expr, Expr), Maybe (Expr, Expr))
shortestPrefix e1 e2 = 
    if' (exprWidth e1' == exprWidth e2') ((e1', e2'), combSuffix me1' me2') $
    if' (exprWidth e1' <  exprWidth e2') ((e1', exprSlice e2' (0, exprWidth e1' - 1)), 
                                          combSuffix me1' (Just $ econcat $ catMaybes [Just $ exprSlice e2' (exprWidth e1', exprWidth e2' - 1), me2'])) $
    ((exprSlice e1' (0, exprWidth e2' - 1), e2'), 
     combSuffix (Just $ econcat $ catMaybes [Just $ exprSlice e1' (exprWidth e2', exprWidth e1' - 1), me1']) me2')

    where 
    (e1', me1') = pref e1
    (e2', me2') = pref e2

    pref :: Expr -> (Expr, Maybe Expr)
    pref (EBinOp BConcat i1 i2) = (i1', Just $ econcat $ catMaybes [mi1', Just i2]) where (i1', mi1') = pref i1
    pref i                      = (i,  Nothing)
    
    combSuffix :: Maybe Expr -> Maybe Expr -> Maybe (Expr, Expr)
    combSuffix Nothing   Nothing   = Nothing
    combSuffix (Just s1) (Just s2) = Just (s1,s2)

fRelIntEq1 :: (?spec::Spec) => (Expr, Expr) -> Formula
fRelIntEq1 (e1,e2) | exprWidth e1 <= maxAVarIntWidth && isConstExpr e2 = FEqConst       (AVarInt $ scalarExprToTerm e1) i where i = fromInteger $ ivalVal $ evalConstExpr e2
fRelIntEq1 (e1,e2) | exprWidth e1 <= maxAVarIntWidth                   = FEq            (AVarInt $ scalarExprToTerm e1) (AVarInt $ scalarExprToTerm e2)
                   | otherwise                                         = bvRelNormalise REq (PTInt $ scalarExprToTerm e1) (PTInt $ scalarExprToTerm e2)


fVar :: (?spec::Spec) => Formula -> [Var]
fVar FTrue            = []
fVar FFalse           = []
fVar (FEq v1 v2)      = avarVar v1 ++ avarVar v2
fVar (FEqConst v _)   = avarVar v
fVar (FBoolAVar v)    = avarVar v
fVar (FBinOp _ f1 f2) = fVar f1 ++ fVar f2
fVar (FNot f)         = fVar f


fAbsVars :: (?spec::Spec) => Formula -> [AbsVar]
fAbsVars = nub . fAbsVars'

fAbsVars' :: (?spec::Spec) => Formula -> [AbsVar]
fAbsVars' FTrue            = []
fAbsVars' FFalse           = []
fAbsVars' (FBoolAVar av)   = [av]
fAbsVars' (FEq av1 av2)    = [av1, av2]
fAbsVars' (FEqConst av _)  = [av]
fAbsVars' (FBinOp _ f1 f2) = fAbsVars' f1 ++ fAbsVars' f2         
fAbsVars' (FNot f)         = fAbsVars' f

formToExpr :: (?spec::Spec) => Formula -> Expr
formToExpr FTrue             = true
formToExpr FFalse            = false
formToExpr (FBoolAVar av)    = avarToExpr av
formToExpr (FEq av1 av2)     = EBinOp Eq (avarToExpr av1) (avarToExpr av2)
formToExpr (FEqConst av i)   = EBinOp Eq (avarToExpr av) (EConst $ avarValToConst av i)
formToExpr (FBinOp op f1 f2) = EBinOp (boolOpToBOp op) (formToExpr f1) (formToExpr f2)
formToExpr (FNot f)          = EUnOp Not $ formToExpr f
