-- Theory solver that uses bitvector library for existential quantification
-- and SMTLib2 for satisfiability checking and unsat cores

{-# LANGUAGE ImplicitParams, RecordWildCards #-}

module BVSMT(bvSolver, 
             bvRelNormalise,
             bvTermNormalise) where

import Data.Maybe
import Data.List
import Control.Monad.State.Lazy
import Control.Monad.ST
import qualified Data.Map as M
import Debug.Trace

import Util hiding (trace)
import qualified BV.Types    as BV
import qualified BV.Canonize as BV
import qualified BV.Util     as BV
import qualified CuddExplicitDeref as C
import SMTSolver
import Predicate
import BFormula
import ISpec
import IExpr
import IType
import IVar
import RefineCommon
import GroupTag
import ACFA2HAST
import Ops
import qualified HAST.BDD as H

type VarMap = M.Map String Term

--------------------------------------------------------------------
-- Normalisation interface
--------------------------------------------------------------------

bvRelNormalise :: (?spec::Spec) => RelOp -> Term -> Term -> Either Bool (PredOp, Term, Term)
bvRelNormalise REq  t1 t2 = bvRelNormalise' BV.Eq  t1 t2
bvRelNormalise RNeq _  _  = error "Unexpected '!=' in bvRelNormalise"
bvRelNormalise RLt  t1 t2 = bvRelNormalise' BV.Lt  t1 t2
bvRelNormalise RGt  t1 t2 = bvRelNormalise' BV.Lt  t2 t1
bvRelNormalise RLte t1 t2 = bvRelNormalise' BV.Lte t1 t2
bvRelNormalise RGte t1 t2 = bvRelNormalise' BV.Lte t2 t1

bvRelNormalise' :: (?spec::Spec) => BV.Rel -> Term -> Term -> Either Bool (PredOp, Term, Term)
bvRelNormalise' r t1 t2 = 
    case BV.atomToCAtom a of
         Left b                       -> Left b
         Right (BV.CAtom op' ct1 ct2) -> let ?vmap = vmap in
                                         let pop = case op' of
                                                        BV.Eq  -> PEq
                                                        BV.Lt  -> PLt
                                                        BV.Lte -> PLte in
                                         Right (pop, scalarExprToTerm $ ctermToExp ct1, scalarExprToTerm $ ctermToExp ct2)
    where a = BV.Atom r t1' t2'
          ((t1', t2'), vmap) = runState (do _t1 <- termToBVTerm t1
                                            _t2 <- termToBVTerm t2
                                            return (_t1, _t2)) M.empty

bvTermNormalise :: (?spec::Spec) => Term -> Term
bvTermNormalise t = let ?vmap = vmap in scalarExprToTerm $ ctermToExp ct
    where (t', vmap) = runState (termToBVTerm t) M.empty
          ct = BV.termToCTerm t'

--------------------------------------------------------------------
-- SMT solver interface
--------------------------------------------------------------------

bvSolver :: Spec -> SMTSolver -> C.STDdManager s u  -> TheorySolver s u AbsVar AbsVar Var
bvSolver spec solver m = TheorySolver { unsatCoreState      = bvUnsatCore           spec solver
                                      , unsatCoreStateLabel = bvUnsatCoreStateLabel spec solver
                                      , eQuant              = bvEquantTmp           spec solver m
                                      , getVarsLabel        = let ?spec = spec in (\av -> filter ((==VarTmp) . varCat) $ avarVar av)
                                      }

bvUnsatCore :: Spec -> SMTSolver -> [(AbsVar,[Bool])] -> Maybe [(AbsVar,[Bool])]
bvUnsatCore _ solver ps = 
    case smtGetModel solver 
         $ map (uncurry avarAsnToFormula . mapSnd boolArrToBitsBe) 
         $ filter (not . avarIsRelPred . fst) ps of
         Just (Left core) -> Just $ map (ps !!) core
         Just (Right _)   -> Nothing
         Nothing          -> error $ "bvUnsatCore: could not solve instance: " ++ show ps

bvUnsatCoreStateLabel :: Spec -> SMTSolver -> [(AbsVar, [Bool])] -> [(AbsVar, [Bool])] -> Maybe ([(AbsVar, [Bool])], [(AbsVar, [Bool])])
bvUnsatCoreStateLabel spec solver sps lps = 
    case bvUnsatCore spec solver (lps++sps) of
         Just core -> let ?spec = spec in Just $ partition ((==VarState) . avarCategory . fst) core
         _         -> Nothing

bvEquantTmp :: Spec -> SMTSolver -> C.STDdManager s u -> [(AbsVar,[Bool])] -> PVarOps pdb s u -> StateT pdb (ST s) (C.DDNode s u)
bvEquantTmp spec solver m avs ops = 
    let ?spec = spec
    in bvEquant spec solver m ops avs
       $ nub
       $ map varName
       $ filter ((== VarTmp) . varCat) 
       $ concatMap (avarVar . fst) avs

bvEquant :: Spec -> SMTSolver -> C.STDdManager s u -> PVarOps pdb s u -> [(AbsVar,[Bool])] -> [String] -> StateT pdb (ST s) (C.DDNode s u)
bvEquant spec solver m ops avs vs = do
    let ?spec = spec
    let -- Deal with arrays and pointers. 
        dnf = resolveAddresses 
              $ resolveIndices 
              $ return 
              $ map avarToRel 
              $ filter (not . avarIsRelPred . fst) avs
        f = fdisj $ map (equant' vs solver) dnf
    H.compileBDD m ops (avarGroupTag . bavarAVar) $ compileFormula $ trace ("bvEquant " ++ show avs ++ " = " ++ show f) $ f

equant' :: (?spec::Spec) => [String] -> SMTSolver -> [(BV.Rel, Term, Term)] -> Formula
equant' vs solver rels = 
    -- Check formula's satisfiability and validity using SMT solver first.
    -- The BV solver only detects unsat and valid formulas in few special cases.
    if' (smtCheckSAT solver forms == Just False)                      FFalse
    $ if' (smtCheckSAT solver [fdisj $ map fnot forms] == Just False) FTrue
    $ case BV.exTerm qvs atoms of
           Just (Left True)  -> FTrue
           Just (Left False) -> FFalse
           Just (Right cas)  -> fconj $ map (catomToForm vmap) cas
           Nothing           -> error $ "bvEquant failed on: " ++ show atoms
    where forms         = map (\(r, t1, t2) -> ptrFreeBExprToFormula $ EBinOp (bvRelToOp r) (termToExpr t1) (termToExpr t2)) rels
          ((atoms, qvs), vmap) = runState (do _atoms <- mapM relToAtom rels
                                              _qvs   <- mapM mkVar vs
                                              return (_atoms, concat _qvs)) M.empty

mkVar :: (?spec::Spec) => String -> State VarMap [BV.Var]
mkVar n = do
    let scalars = map scalarExprToTerm $ exprScalars (EVar n) (typ $ EVar n)
    mapM (\t -> do varMapInsert t
                   return $ BV.Var (show t) (termWidth t)) scalars

--------------------------------------------------------------------
-- Conversion to data structures of the BV library
--------------------------------------------------------------------

varMapInsert :: Term -> State VarMap ()
varMapInsert t = modify (M.insert (show t) t)

avarToRel :: (?spec::Spec) => (AbsVar, [Bool]) -> (BV.Rel, Term, Term)
avarToRel (AVarPred (PAtom op t1 t2), [val])   = case (op, val) of
                                                      (PEq , True ) -> (BV.Eq , ptermTerm t1, ptermTerm t2)
                                                      (PEq , False) -> (BV.Neq, ptermTerm t1, ptermTerm t2)
                                                      (PLt , True ) -> (BV.Lt , ptermTerm t1, ptermTerm t2)
                                                      (PLt , False) -> (BV.Lte, ptermTerm t2, ptermTerm t1)
                                                      (PLte, True ) -> (BV.Lte, ptermTerm t1, ptermTerm t2)
                                                      (PLte, False) -> (BV.Lt , ptermTerm t2, ptermTerm t1)
avarToRel (AVarBool t               , [True])  = (BV.Eq , t, TTrue) 
avarToRel (AVarBool t               , [False]) = (BV.Neq, t, TTrue) 
avarToRel (AVarInt  t               , val)     = (BV.Eq , t, TUInt (length val) (boolArrToBitsBe val))
avarToRel (AVarEnum t               , val)     = (BV.Eq , t, TEnum $ (enumEnums $ getEnumeration n) !! (boolArrToBitsBe val))
                                                 where Enum n = typ t

-- TODO: Add pair-wise inequality constraints between
-- AddrOf terms
resolveAddresses :: [[(BV.Rel, Term, Term)]] -> [[(BV.Rel, Term, Term)]]
resolveAddresses = id

-- Identify terms isomorphic up to array indices, e.g.,
-- x[i].field and x[j].field.  Transform the input DNF:
-- (i == j /\ dnf (with i substituted by j)) \/ (i /= j /\ dnf)
-- Every such transformation doubles the size of DNF.
-- Since equation i==j may introduce new isomorphic predicates,
-- continue the process recursively until no new isomorphic pairs
-- can be found.  
-- Hopefully, this nasty piece of logic is sufficient to add 
-- support for array logic to our decision procedure.
resolveIndices :: [[(BV.Rel, Term, Term)]] -> [[(BV.Rel, Term, Term)]]
resolveIndices = resolveIndices' []

resolveIndices' :: [(Term,Term)] -> [[(BV.Rel, Term, Term)]] -> [[(BV.Rel, Term, Term)]]
resolveIndices' iso0 dnf | isNothing miso = dnf
                         | otherwise      = resolveIndices' ((t1,t2):iso0) dnf'
   where miso = listToMaybe
                $ filter (\pair -> not $ elem pair iso0)                          -- ignore pairs that have already been resolved
                $ (concat . mapMaybe termsIsomorphic)                             -- extract pairs of non-matching indices
                $ (pairs . nub)                                                   -- all unique pairs of non-equal terms
                $ concatMap (\(_, t1',t2') -> scalarTerms t1' ++ scalarTerms t2') -- extract all terms with indices from DNF
                $ concat dnf
         Just (t1,t2) = miso
         t1eqt2   = (BV.Eq, t1, t2)
         t1neqt2  = (BV.Neq, t1,t2)
         -- substitute t1 with t2 throughout dnf
         dnfsubst = map (map (\(r, t1', t2') -> (r, subst t1 t2 t1', subst t1 t2 t2'))) dnf
         dnf'     = (map (t1eqt2:) dnfsubst) ++ (map (t1neqt2:) dnf)

subst :: Term -> Term -> Term -> Term
subst old new t                 | t == old = new
subst old new (TAddr t)                    = TAddr $ subst old new t
subst old new (TField t f)                 = TField (subst old new t) f
subst old new (TIndex t i)                 = TIndex (subst old new t) (subst old new i)
subst old new (TUnOp op t)                 = TUnOp op $ subst old new t
subst old new (TBinOp op t1 t2)            = TBinOp op (subst old new t1) (subst old new t2)
subst old new (TSlice t s)                 = TSlice (subst old new t) s
subst old _   _                            = old

-- If terms are isomorphic modulo indices, and at least one index is not a constant,
-- returns all pairs of index expressions that are not equal.
termsIsomorphic :: (Term, Term) -> Maybe [(Term, Term)]
termsIsomorphic (TAddr t1    , TAddr t2)                   = termsIsomorphic (t1, t2)
termsIsomorphic (TField t1 f1, TField t2 f2) | f1 == f2    = termsIsomorphic (t1, t2)
termsIsomorphic (TIndex t1 i1, TIndex t2 i2) | isJust miso = fmap ((fromJust miso) ++ ) $ isoPair i1 i2
                                             where miso = termsIsomorphic (t1, t2)
termsIsomorphic (_,_)                                      = Nothing

isoPair :: Term -> Term -> Maybe [(Term, Term)]
isoPair i1 i2 | i1 == i2                         = Just []
              | isConstTerm i1 && isConstTerm i2 = Nothing -- assumes that all constant expressions were evaluated and are represented by equal constant terms
              | otherwise                        = Just [(i1,i2)]

scalarTerms :: Term -> [Term]
scalarTerms   (TVar _)         = []
scalarTerms   (TSInt _ _)      = []
scalarTerms   (TUInt _ _)      = []
scalarTerms   (TEnum _)        = []
scalarTerms   TTrue            = []
scalarTerms t@(TAddr _)        = [t]
scalarTerms t@(TField _ _)     = [t]
scalarTerms t@(TIndex _ _)     = [t]
scalarTerms   (TUnOp _ t)      = scalarTerms t
scalarTerms   (TBinOp _ t1 t2) = scalarTerms t1 ++ scalarTerms t2
scalarTerms   (TSlice t _)     = scalarTerms t

relToAtom :: (?spec::Spec) => (BV.Rel, Term, Term) -> State VarMap BV.Atom
relToAtom (rel, t1, t2) = do 
    t1' <- termToBVTerm t1
    t2' <- termToBVTerm t2
    return $ BV.Atom rel t1' t2'

termToBVTerm :: (?spec::Spec) => Term -> State VarMap BV.Term
termToBVTerm   (TSlice t s)             = do t' <- termToBVTerm t
                                             return $ BV.TSlice t' s
termToBVTerm   (TBinOp ABConcat t1 t2)  = do t1' <- termToBVTerm t1
                                             t2' <- termToBVTerm t2
                                             return $ BV.TConcat [t1',t2'] 
termToBVTerm   (TBinOp APlus t1 t2)     = do t1' <- termToBVTerm t1
                                             t2' <- termToBVTerm t2
                                             let w = max (BV.width t1') (BV.width t2')
                                             return $ BV.TPlus [BV.termExt t1' w, BV.termExt t2' w]
termToBVTerm   (TBinOp ABinMinus t1 t2) = do t1' <- termToBVTerm t1
                                             t2' <- termToBVTerm t2
                                             let w = max (BV.width t1') (BV.width t2')
                                             return $ BV.TPlus [BV.termExt t1' w, BV.TMul ((-1) `BV.mod2` w) t2' w]
termToBVTerm   (TBinOp AMod t1 t2)      | isConstTerm t2 && (isPow2 $ ivalVal $ evalConstExpr $ termToExpr t2) 
                                        = do t1' <- termToBVTerm t1
                                             return $ BV.termExt (BV.TSlice t1' (0, (log2 $ ivalVal $ evalConstExpr $ termToExpr t2) - 1)) (termWidth t1)
termToBVTerm   (TBinOp AMul t1 t2)      | isConstTerm t1 
                                        = do t2' <- termToBVTerm t2
                                             return $ BV.TMul ((ivalVal $ evalConstExpr $ termToExpr t1) `BV.mod2` w) t2' w
                                        | isConstTerm t2
                                        = do t1' <- termToBVTerm t1
                                             return $ BV.TMul ((ivalVal $ evalConstExpr $ termToExpr t2) `BV.mod2` w) t1' w
                                        where w = max (termWidth t1) (termWidth t2)
termToBVTerm   (TUnOp AUMinus t)        = do t' <- termToBVTerm t
                                             let w = termWidth t
                                             return $ BV.TMul ((-1) `BV.mod2` w) t' w
termToBVTerm   (TUnOp ABNeg t)          = do t' <- termToBVTerm t
                                             return $ BV.TNeg t'
termToBVTerm   (TSInt w i)              = return $ BV.tConst i w
termToBVTerm   (TUInt w i)              = return $ BV.tConst i w
termToBVTerm   TTrue                    = return $ BV.tConst 1 1
termToBVTerm t@(TEnum n)                = return $ BV.tConst (toInteger $ enumToInt n) (termWidth t)
termToBVTerm t@(TVar _)                 = do varMapInsert t
                                             return $ BV.TVar (BV.Var (show t) (termWidth t))
termToBVTerm t@(TField _ _)             = do varMapInsert t
                                             return $ BV.TVar (BV.Var (show t) (termWidth t))
termToBVTerm t@(TIndex _ _)             = do varMapInsert t
                                             return $ BV.TVar (BV.Var (show t) (termWidth t))
termToBVTerm t@(TAddr _)                = do varMapInsert t
                                             return $ BV.TVar (BV.Var (show t) (termWidth t))
termToBVTerm t                          = error $ "termToBVTerm: term not supported: " ++ show t

--------------------------------------------------------------------
-- Conversion back to our data structures
--------------------------------------------------------------------

catomToForm :: (?spec::Spec) => VarMap -> BV.CAtom -> Formula
catomToForm vmap (BV.CAtom rel ct1 ct2) = 
    let ?vmap = vmap in ptrFreeBExprToFormula $ fixupTypes $ EBinOp (bvRelToOp rel) (ctermToExp ct1) (ctermToExp ct2)

bvRelToOp :: BV.Rel -> BOp
bvRelToOp BV.Eq  = Eq
bvRelToOp BV.Neq = Neq
bvRelToOp BV.Lt  = Lt
bvRelToOp BV.Lte = Lte

-- Change integer constants to enums where appropriate
fixupTypes :: (?spec::Spec) => Expr -> Expr
fixupTypes (EBinOp op e1 e2) = EBinOp op e1' e2'
    where
    e2' = case typ e1 of 
               Enum n -> if' (isConstExpr e2) (EConst $ EnumVal $ (enumEnums $ getEnumeration n) !! fromInteger (ivalVal $ evalConstExpr e2)) e2
               _      -> e2
    e1' = case typ e1 of
               Enum n -> if' (isConstExpr e1) (EConst $ EnumVal $ (enumEnums $ getEnumeration n) !! fromInteger (ivalVal $ evalConstExpr e1)) e1
               _      -> e1

ctermToExp :: (?spec::Spec, ?vmap::VarMap) => BV.CTerm -> Expr
ctermToExp t@BV.CTerm{..} | null ctVars
                          = bvconstToExpr ctConst
                          | BV.cVal ctConst == 0 && (length ctVars == 1)
                          = ctvarToExpr (BV.width t) (head ctVars)
                          | otherwise
                          = plus $ (map (ctvarToExpr (BV.width t)) ctVars) ++ if' (BV.cVal ctConst == 0) [] [bvconstToExpr ctConst]

bvconstToExpr :: BV.Const -> Expr
bvconstToExpr BV.Const{..} = EConst $ UIntVal cWidth cVal

ctvarToExpr :: (?spec::Spec, ?vmap::VarMap) => Int -> (Integer, (BV.Var, (Int,Int))) -> Expr
ctvarToExpr w (c, (v,(l,h))) = vmul
    where v' = termToExpr $ ?vmap M.! (BV.vName v)
          vslice = if' ((l==0) && (h == BV.vWidth v - 1)) v' (ESlice v' (l,h))
          vext = if' (h - l + 1 == w) vslice                                                          $
                 if' (h - l + 1 < w)  (EBinOp BConcat vslice (EConst $ UIntVal (w - (h - l + 1)) 0)) $
                 exprSlice vslice (0, w - 1)
          vmul = if' (c == 1) vext (EBinOp Mul (EConst $ UIntVal w 0) vext)
