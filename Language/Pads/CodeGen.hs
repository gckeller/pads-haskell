{-# LANGUAGE TemplateHaskell, NamedFieldPuns, ScopedTypeVariables,
             RecordWildCards, UndecidableInstances #-}

{-
** *********************************************************************
*                                                                      *
*         (c)  Kathleen Fisher <kathleen.fisher@gmail.com>             *
*              John Launchbury <john.launchbury@gmail.com>             *
*                                                                      *
************************************************************************
-}

module Language.Pads.CodeGen where

import Language.Pads.Syntax as PS
import Language.Pads.MetaData
import Language.Pads.Generic
import Language.Pads.PadsParser
import Language.Pads.CoreBaseTypes
import Language.Pads.TH
import qualified Language.Pads.Errors as E
import qualified Language.Pads.Source as S
import Language.Pads.LazyList

import Language.Haskell.TH 
import Language.Haskell.Syntax

import Data.Data
import Data.Char
import qualified Data.Map as M
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import Control.Monad

type BString = S.RawStream




make_pads_declarations :: [PadsDecl] -> Q [Dec]
make_pads_declarations ds = fmap concat (mapM genPadsDecl ds)


----------------------------------------------------------------------------
-- GENERATE DECLARATIONS AND CODE FROM INDIVIDUAL PADS DECLARATIONS
----------------------------------------------------------------------------

genPadsDecl :: PadsDecl -> Q [Dec]

genPadsDecl (PadsDeclType old name args pat padsTy) = do
  { let typeDecs = mkTyRepMDDecl old name args padsTy
  ; parseM  <- genPadsParseM name args pat padsTy
  ; parseS  <- genPadsParseS name args pat
  ; printFL <- genPadsPrintFL name args pat padsTy
  ; return (typeDecs ++ parseM ++ parseS ++ printFL)
  }

genPadsDecl (PadsDeclData old name args pat padsData derives) = do
  { let dataDecs = mkDataRepMDDecl old name args padsData derives
  ; parseM <- genPadsDataParseM name args pat padsData 
  ; parseS <- genPadsParseS name args pat
  ; let instances = mkPadsInstance name args (fmap patType pat)
  ; return (dataDecs ++ parseM ++ parseS ++ [instances] ) --  ++ printFL)
  }

genPadsDecl (PadsDeclNew old name args pat branch derives) = do
  { let dataDecs = mkNewRepMDDecl old name args branch derives
  ; parseM <- genPadsNewParseM name args pat branch 
  ; parseS <- genPadsParseS name args pat
  ; let instances = mkPadsInstance name args (fmap patType pat)
  ; return (dataDecs ++ parseM ++ parseS ++ [instances] ) --  ++ printFL)
  }

patType :: Pat -> Type
patType p = case p of
  LitP lit -> case lit of
                CharL c   -> VarT ''Char
                StringL s -> VarT ''String
  TupP ps  -> mkTupleT (map patType ps)
  SigP p t -> t


-----------------------------------------------------------
-- GENERATE REP/MD TYPE DECLARATIONS
-----------------------------------------------------------

mkTyRepMDDecl :: Bool -> UString -> [UString] -> PadsTy -> [Dec]
mkTyRepMDDecl old name args ty 
  = (if old then [] else [repType]) ++ [mdType]
  where
    repType = TySynD (mkRepName name) tyArgs (mkRepTy ty)
    mdType  = TySynD (mkMDName name) tyArgs (mkMDTy ty)
    tyArgs  = map (PlainTV . mkName) args


-----------------------------------------------------------
-- GENERATE REP/MD DATA DECLARATIONS
-----------------------------------------------------------

mkDataRepMDDecl :: Bool -> UString -> [LString] -> PadsData -> [UString] -> [Dec]
mkDataRepMDDecl old name args branches ds
  = (if old then [] else [dataDecl]) ++ [mdDecl, imdDecl]
  where
    dataDecl = DataD [] (mkRepName name) tyArgs (map mkRepUnion bs) (derive ds)
    imdDecl  = DataD [] (mkIMDName name) tyArgs (map mkMDUnion bs) (derive [])
    mdDecl   = TySynD   (mkMDName name)  tyArgs (mkTupleT [ConT ''Base_md, imdApp])
    tyArgs   = map (PlainTV . mkName) args
    imdApp   = foldl AppT (ConT (mkIMDName name)) (map (VarT . mkName) args)
    bs       = case branches of
                 PUnion bnchs    -> bnchs
                 PSwitch exp pbs -> [b | (p,b) <- pbs]

mkRepUnion :: BranchInfo -> Con
mkRepUnion (BConstr c args expM) = NormalC (mkConstrName c) reps
  where   
    reps = [(strict,mkRepTy ty) | (strict,ty) <- args, hasRep ty]
mkRepUnion (BRecord c fields expM) = RecC (mkConstrName c) lreps
  where   
    lreps = [(mkName l,strict,mkRepTy ty) | (Just l,(strict,ty),_) <- fields, hasRep ty]

mkMDUnion :: BranchInfo -> Con
mkMDUnion (BConstr c args expM) = NormalC (mkConstrIMDName c) mds
  where   
    mds = [(NotStrict,mkMDTy ty) | (_,ty) <- args, hasRep ty]
mkMDUnion (BRecord c fields expM) = RecC (mkConstrIMDName c) lmds
  where   
    lmds = [(mkFieldMDName l,NotStrict,mkMDTy ty) | (Just l,(_,ty),_) <- fields, hasRep ty]

derive :: [UString] -> [Name]
derive ds =  map mkName ds
  ++ [mkName d | d<-["Show","Eq","Typeable","Data","Ord"], not (d `elem` ds)]


-----------------------------------------------------------
-- GENERATE REP/MD NEWTYPE DECLARATIONS
-----------------------------------------------------------

mkNewRepMDDecl :: Bool -> UString -> [LString] -> BranchInfo -> [UString] -> [Dec]
mkNewRepMDDecl old name args branch ds
  = (if old then [] else [dataDecl]) ++ [mdDecl, imdDecl]
  where
    dataDecl = NewtypeD [] (mkRepName name) tyArgs (mkRepUnion branch) (derive ds)
    imdDecl  = NewtypeD [] (mkIMDName name) tyArgs (mkMDUnion branch) (derive [])
    mdDecl   = TySynD   (mkMDName name)  tyArgs (mkTupleT [ConT ''Base_md, imdApp])
    tyArgs   = map (PlainTV . mkName) args
    imdApp   = foldl AppT (ConT (mkIMDName name)) (map (VarT . mkName) args)


-----------------------------------------------------------
-- GENERATE REPRESENTATION TYPE OF A TYPE EXPRESSION
-----------------------------------------------------------

mkRepTy ::  PadsTy -> Type
mkRepTy ty = case ty of
  PPartition pty exp          -> mkRepTy pty
  PConstrain pat pty exp      -> mkRepTy pty 
  PTransform tySrc tyDest exp -> mkRepTy tyDest 
  PList ty sep term           -> mkRepList ty
  PApp tys expM               -> mkRepApp tys
  PTuple tys                  -> mkRepTuple tys
  PExpression _               -> ConT ''()
  PTycon c                    -> ConT (mkRepName c)
  PTyvar v                    -> VarT (mkName v)  

mkRepList :: PadsTy -> Type
mkRepList ty = AppT ListT (mkRepTy ty)

mkRepApp :: [PadsTy] -> Type
mkRepApp tys = foldl1 AppT [mkRepTy ty | ty <- tys, hasRep ty]

mkRepTuple :: [PadsTy] -> Type
mkRepTuple tys = case reps of  
    []     -> ConT ''()
    [ty]   -> ty
    (t:ts) -> mkTupleT reps
  where
    reps = [mkRepTy ty | ty <- tys, hasRep ty]
  

-----------------------------------------------------------
-- GENERATE META-DATA REPRESENTATION OF TYPE EXPRESSION
-----------------------------------------------------------

mkMDTy ::  PadsTy -> Type
mkMDTy ty = case ty of
  PPartition pty exp          -> mkMDTy pty
  PConstrain pat pty exp      -> mkMDTy pty 
  PTransform tySrc tyDest exp -> mkMDTy tyDest 
  PList ty sep term           -> mkMDList ty
  PApp tys expM               -> mkMDApp tys
  PTuple tys                  -> mkMDTuple tys
  PExpression _               -> ConT ''Base_md
  PTycon c                    -> ConT (mkMDName c)
  PTyvar v                    -> VarT (mkName v)  

mkMDList :: PadsTy -> Type
mkMDList ty = mkTupleT [ConT ''Base_md, ListT `AppT` mkMDTy ty]    

mkMDApp :: [PadsTy] -> Type
mkMDApp tys = foldl1 AppT [mkMDTy ty | ty <- tys, hasRep ty]

mkMDTuple :: [PadsTy] -> Type
mkMDTuple tys = case mds of  
    []     -> ConT ''Base_md
    [m]    -> mkTupleT [ConT ''Base_md, m] 
    (m:ms) -> mkTupleT [ConT ''Base_md, mkTupleT mds]
  where
    mds = [mkMDTy ty | ty <- tys, hasRep ty]


-----------------------------------------------------------------
-- GENERATING INSTANCE DECLARATIONS FROM DATA/NEW DECLARATION
------------------------------------------------------------------

mkPadsInstance :: UString -> [LString] -> Maybe Type -> Dec
mkPadsInstance str args Nothing 
  = buildInst str args (ConT ''Pads) (VarP 'parsePP) (VarP 'printFL)
mkPadsInstance str args (Just ety) 
  = buildInst str args (ConT ''Pads1 `AppT` ety) (VarP 'parsePP1) (VarP 'printFL1)

buildInst str args pads parse print
  = InstanceD cxt inst [parsePP_method, printFL_method]
  where
    inst    = applyT [pads, ty_name, md_ty]
    ty_name = applyT (ConT (mkName str) : map fst argpairs)
    md_ty   = applyT (ConT (mkMDName str) : map snd argpairs)
    parsePP_method = ValD parse (NormalB (applyE (VarE (mkTyParserName str) : [VarE 'parsePP | a <- args]))) []
    printFL_method = ValD print (NormalB (VarE 'dummyPrintFL)) [] -- (mkPrintFLName str))) []
    argpairs = [(VarT (mkName a), VarT (mkName (a++"_md"))) | a <- args]

    cxt = [ClassP ''Pads [r,m] | (r,m) <- argpairs]

dummyPrintFL = error "printFL is not yet defined"


-----------------------------------------------------------------
-- GENERATING PARSER DECLARATION FROM TYPE/DATA/NEW DECLARATION
------------------------------------------------------------------

genPadsParseM :: UString -> [LString] -> Maybe Pat -> PadsTy -> Q [Dec]
genPadsParseM name args patM padsTy = do 
  { body  <- genParseTy padsTy
  ; return [FunD parser_name [Clause parserArgs (NormalB body) []] ]
  }
  where
    (parser_name,parserArgs) = mkParserNameArgs name args patM

genPadsDataParseM :: UString -> [LString] -> (Maybe Pat) -> PadsData -> Q [Dec] 
genPadsDataParseM name args patM padsData = do 
  { body  <- genParseData padsData
  ; return [ FunD parser_name [Clause parserArgs (NormalB body) []] ]
  }
  where
    (parser_name,parserArgs) = mkParserNameArgs name args patM

genPadsNewParseM :: UString -> [LString] -> (Maybe Pat) -> BranchInfo -> Q [Dec] 
genPadsNewParseM name args patM branch = do 
  { (dec,exp) <- genParseBranchInfo branch
  ; let body = LetE [dec] exp
  ; return [ FunD parser_name [Clause parserArgs (NormalB body) []] ]
  }
  where
    (parser_name,parserArgs) = mkParserNameArgs name args patM

mkParserNameArgs :: UString -> [LString] -> Maybe Pat -> (Name, [Pat])
mkParserNameArgs name args patM = (parserName, parserArgs)
  where
    parserName = mkTyParserName name    
    parserArgs = map (VarP . mkVarParserName) args ++ pat
    pat = Maybe.maybeToList patM


--------------------------------------------------------------
-- GENERATING STRING-PARSER DECLARATION
--------------------------------------------------------------

genPadsParseS :: UString -> [LString] -> Maybe Pat -> Q [Dec]
genPadsParseS name args patM = do 
  { bodyS <- [| parseStringInput $(return foo) |]
  ; return [ FunD (mkTyParserSName name) [Clause parserArgs (NormalB bodyS) []] ]
  }
  where
    parserName = mkTyParserName name    
    parserArgs = map (VarP . mkVarParserName) args ++ pat
    foo = applyE (VarE (mkTyParserName name) : map patToExp parserArgs)
    pat = Maybe.maybeToList patM


------------------------------------------------------
-- GENERATING PARSER FROM TYPE EXPRESSION
------------------------------------------------------

genParseTy :: PadsTy -> Q Exp
genParseTy pty = case pty of
    PConstrain pat ty exp   -> genParseConstrain (return pat) ty (return exp)
    PTransform src dest exp -> genParseTyTrans src dest (return exp)
    PList ty sep term       -> genParseList ty sep term
    PPartition ty exp       -> genParsePartition ty exp
    PApp tys argE           -> genParseTyApp tys argE
    PTuple tys              -> genParseTuple tys
    PExpression exp         -> genParseExp exp
    PTycon c                -> return $ mkParseTycon c
    PTyvar v                -> return $ mkParseTyvar v

genParseConstrain :: Q Pat -> PadsTy -> Q Exp -> Q Exp
genParseConstrain patQ ty expQ = [| parseConstraint $(genParseTy ty) $pred |]
  where
    pred = lamE [patQ, varP (mkName "md")] expQ

genParseTyTrans :: PadsTy -> PadsTy -> Q Exp -> Q Exp
genParseTyTrans tySrc tyDest expQ
  = [| parseTransform $(genParseTy tySrc) (fst $expQ) |]

genParseList :: PadsTy -> (Maybe PadsTy) -> (Maybe TermCond) -> Q Exp
genParseList ty sep term =
  case (sep,term) of 
    (Nothing,  Nothing)          -> [| parseListNoSepNoTerm $(genParseTy ty) |]
    (Just sep, Nothing)          -> [| parseListSepNoTerm $(genParseTy sep) $(genParseTy ty) |]
    (Nothing,  Just (LLen lenE)) -> [| parseListNoSepLength $(return lenE) $(genParseTy ty) |]
    (Just sep, Just (LLen lenE)) -> [| parseListSepLength $(genParseTy sep) $(return lenE) $(genParseTy ty) |]
    (Nothing,  Just (LTerm term))-> [| parseListNoSepTerm $(genParseTy term) $(genParseTy ty) |]
    (Just sep, Just (LTerm term))-> [| parseListSepTerm $(genParseTy sep) $(genParseTy term) $(genParseTy ty) |]

genParsePartition :: PadsTy -> Exp -> Q Exp
genParsePartition ty dis = [| parsePartition $(genParseTy ty) $(return dis) |]

genParseTuple :: [PadsTy] -> Q Exp
genParseTuple []  = [| return ((), cleanBasePD) |]
genParseTuple tys = do
  { let f_rep = buildF_rep vars_frep
  ; let f_md  = buildF_md vars_fmd vars_frep 
  ; body  <- foldl parseNext [| return ($(dyn "f_rep"),$(dyn "f_md")) |] tys
  ; return (LetE [f_rep,f_md] body)
  }
  where
    vars_frep = [v | (v,t) <- zip vars_fmd tys, hasRep t]
    vars_fmd  = [ mkName ("x"++show n) | n <- [1 .. length tys]] 

parseNext :: Q Exp -> PadsTy -> Q Exp
parseNext prog t
  | hasRep t  = [| $prog =@= $(genParseTy t) |]
  | otherwise = [| $prog =@  $(genParseTy t) |]

buildF_rep :: [Name] -> Dec
buildF_rep vars_frep
  = FunD (mkName "f_rep") [Clause
         (map VarP vars_frep) (NormalB (TupE (map VarE vars_frep))) [] ]

buildF_md :: [Name] -> [Name] -> Dec
buildF_md vars_fmd vars_frep 
  = FunD (mkName "f_md") [Clause (map VarP vars_fmd) (NormalB body) []]
  where
    mdHeaders = [ VarE 'get_md_header `AppE` VarE xi | xi <- vars_fmd ]
    body = TupE [mkMergeBaseMDs mdHeaders, TupE (map VarE vars_frep)]

mkMergeBaseMDs :: [Exp] -> Exp
mkMergeBaseMDs [e] = e
mkMergeBaseMDs es  = VarE 'mergeBaseMDs `AppE` ListE es

genMergeBaseMDs e = return (mkMergeBaseMDs e)

genParseExp :: Exp -> Q Exp
genParseExp (LitE (CharL c))   = [| charLit_parseM c |]
genParseExp (LitE (StringL s)) = [| strLit_parseM s |]
genParseExp exp                = [| litParse $(return exp) |]

genParseTyApp :: [PadsTy] -> Maybe Exp -> Q Exp
genParseTyApp tys expM = do
  { fs <- mapM genParseTy tys
  ; return (foldl1 AppE (fs ++ Maybe.maybeToList expM))
  }

mkParseTycon :: String -> Exp
mkParseTycon "EOF" = VarE 'eof_parseM
mkParseTycon "EOR" = VarE 'eor_parseM
mkParseTycon c     = VarE (mkTyParserName c)

mkParseTyvar :: String -> Exp
mkParseTyvar v = VarE (mkVarParserName v) -- should gensym these, but probably ok


----------------------------------------------------------
-- GENERATING PARSERS FROM UNION/SWITCH EXPRESSIONS
----------------------------------------------------------

genParseData :: PadsData -> Q Exp
genParseData (PUnion bs)       = genParseUnion bs
genParseData (PSwitch exp pbs) = genParseSwitch exp pbs

genParseUnion :: [BranchInfo] -> Q Exp
genParseUnion bs = do
  { (decs,bodies) <- fmap unzip $ mapM genParseBranchInfo bs
  ; let body = case bodies of
                 [b] -> b
                 bs  -> (VarE 'choiceP) `AppE` (ListE bs)
  ; return (LetE decs body)
  }

genParseSwitch :: Exp -> [(Pat,BranchInfo)] -> Q Exp
genParseSwitch exp pbs = do
  { let (ps,bs) = unzip pbs
  ; (decs,bodies) <- fmap unzip $ mapM genParseBranchInfo bs
  ; let body = CaseE exp [Match p (NormalB b) [] | (p,b) <- zip ps bodies]
  ; return (LetE decs body)
  }

genParseBranchInfo :: BranchInfo -> Q (Dec,Exp)
genParseBranchInfo (BRecord c fields pred) = genParseRecord c fields pred
genParseBranchInfo (BConstr c args pred) = do
  { body <- foldl parseNext [| return ($(conE (mkConstrName c)),$(varE (mkfnMDName c))) |] tys
  ; return (con_md, body)
  }
  where
    tys  = [ty | (strict,ty) <- args]
    con_md = buildConstr_md (mkfnMDName c) (ConE (mkConstrIMDName c)) tys

buildConstr_md :: Name -> Exp -> [PadsTy] -> Dec
buildConstr_md fnMD conMD tys 
  = FunD fnMD [Clause (map VarP vars_fmd) (NormalB body) []]
  where
    vars_fmd   = [ mkName ("x"++show n) | n <- [1 .. length tys]] 
    mdHeaders  = [ VarE 'get_md_header `AppE` VarE xi | xi <- vars_fmd ]
    body       = TupE [mkMergeBaseMDs mdHeaders, applyE (conMD : map VarE vars_conmd)]
    vars_conmd = [v | (v,t) <- zip vars_fmd tys, hasRep t]


----------------------------------------------------------
-- GENERATING PARSERS FROM RECORD EXPRESSIONS
----------------------------------------------------------

genParseRecord :: UString -> [FieldInfo] -> (Maybe Exp) -> Q (Dec,Exp)
genParseRecord c fields pred = do
  { c_md <- newName (strToLower c)
  ; let con_md = buildConstr_md c_md (ConE (mkConstrIMDName c))
                       [ty | (_,(_,ty),_) <- fields]
  ; labMDs  <- sequence [genLabMDName l | (l,(_,_),_) <- fields] 
  ; let fnMDLabs  = applyE $ map VarE (c_md : labMDs)
  ; doStmts <- sequence [genParseField f xn | (f,xn) <- zip fields labMDs]
  ; returnStmt <- [| return ($(return conLabs),$(return fnMDLabs)) |]
  ; return (con_md, DoE (doStmts ++ [NoBindS returnStmt]))
  }
  where
    labs    = [mkName lab | (Just lab,(_,ty),_) <- fields, hasRep ty]
    conLabs = applyE (ConE (mkConstrName c) : map VarE labs)

genLabMDName (Just lab) = return (mkFieldMDName lab)
genLabMDName Nothing    = newName "x"

genParseField :: FieldInfo -> Name -> Q Stmt
genParseField (labM, (strict, ty), expM) xn = do
  { parseTy <- case expM of 
                Nothing  -> genParseTy ty
                Just exp -> genParseRecConstrain labP (VarP xn) ty exp
  ; return (BindS (TupP [labP, VarP xn]) parseTy)
  }
  where
    labP = case labM of
              Just lab -> VarP (mkName lab)
              Nothing  -> WildP

genParseRecConstrain :: Pat -> Pat -> PadsTy -> Exp -> Q Exp
genParseRecConstrain labP xnP ty exp = [| parseConstraint $(genParseTy ty) $pred |]
  where
    pred = return (LamE [labP, xnP] exp)


----------------------------------------------------
-- GENERATING PRINTING FUNCTION FROM A DECLARATION
----------------------------------------------------

genPadsPrintFL :: UString -> [LString] -> Maybe Pat -> PadsTy -> Q [Dec]
genPadsPrintFL name args patM padsTy = do 
  { body  <- genPrintTy padsTy (Just (TupE (map VarE rm)))
  ; return [FunD printer_name [Clause (printerArgs ++ [TupP (map VarP rm)]) (NormalB body) []] ]
  }
  where
    (printer_name,printerArgs) = mkPrinterNameArgs name args patM
    rm = [mkName "rep", mkName "md"]


mkPrinterNameArgs :: UString -> [LString] -> Maybe Pat -> (Name, [Pat])
mkPrinterNameArgs name args patM = (parserName, parserArgs)
  where
    parserName = mkTyPrinterName name    
    parserArgs = map (VarP . mkTyPrinterVarName) args ++ pat
    pat = Maybe.maybeToList patM



------------------------------------------
-- GENERATE PRINTING FUNCTION FROM A TYPE
------------------------------------------

genPrintTy :: PadsTy -> Maybe Exp -> Q Exp
genPrintTy (PConstrain pat ty exp) rm   = genPrintTy ty rm  -- doesn't check the constraint
genPrintTy (PTransform src dest exp) rm = genPrintTrans src exp rm
--genPrintTy (PList ty sepM termM) rm     = genPrintList ty sepM termM rm
--genPrintTy (PPartition ty exp) rm       = genPrintPartition ty exp rm
--genPrintTy (PApp tys expM) rm           = genPrintTyApp tys expM rm
genPrintTy (PTuple tys) rm              = genPrintTuple tys rm
genPrintTy (PExpression exp) rm         = genPrintExp exp rm
genPrintTy (PTycon c) rm                = genPrintTycon c rm
genPrintTy (PTyvar v) rm                = genPrintTyVar v rm


genPrintTrans :: PadsTy -> Exp -> Maybe Exp -> Q Exp
genPrintTrans tySrc exp Nothing
  = genPrintTy tySrc Nothing
genPrintTrans tySrc exp (Just rm) = do
  { rm' <- [| snd $(return exp) $(return rm) |]
  ; genPrintTy tySrc (Just rm')
  }

{-
genPrintList :: PadsTy -> Maybe PadsTy -> Maybe TermCond -> (Exp,Exp) -> Q Exp
genPrintList ty sepM termM rm
  = [| printList $(genPrintTy ty) $psep $pterm $(return rm) |]
  where
    psep  = maybe [| nil |] (\t -> genPrintTyMD t m) sepM
    pterm = maybe [| nil |] (\t -> genPrintTermCondt m) termM


genPrintTyApp :: [PadsTy] -> Maybe Exp -> Exp -> Q Exp
genPrintTyApp tys expM rm = do
  { prtys <- mapM genPrintTy tys
  ; return (foldr1 AppE (prtys ++ maybe [] (\e->[e]) expM))
  }
-}

{-
intPair_printFL (r,m)
  = case (r,m) of
      ((r1,r2),(_,(m1,m2)))
        -> int_PrintFL (r1,m1) +++
           addString "|" +++
           int_PrintFL (r2,m2)
-}

genPrintTuple :: [PadsTy] -> Maybe Exp -> Q Exp
genPrintTuple tys (Just rm) = do
  { repNamesM <- genNamesforTuple "rep" tys
  ; let repVars = map VarE (Maybe.catMaybes repNamesM)
  ; let repPats = map VarP (Maybe.catMaybes repNamesM)
  ; mdNamesM  <- genNamesforTuple "md" tys
  ; let mdVars = map VarE (Maybe.catMaybes mdNamesM)
  ; let mdPats = map VarP (Maybe.catMaybes mdNamesM)
  ; inners <- sequence [genPrintTupleInner t r m | (t,r,m) <- zip3 tys repNamesM mdNamesM]
  ; return $ CaseE rm
                [Match (TupP [TupP repPats, TupP [WildP, (TupP mdPats)]]) 
                       (NormalB (VarE 'concatFL `AppE` ListE inners))
                       []]
  }
genPrintTuple tys Nothing = do
  { inners <- sequence [genPrintTy t Nothing | t <- tys]
  ; return (VarE 'concatFL `AppE` ListE inners)
  }

genNamesforTuple :: String -> [PadsTy] -> Q [Maybe Name]
genNamesforTuple str tys =
  sequence [if hasRep ty then fmap Just (newName str) else return Nothing | ty <- tys]

genPrintTupleInner t (Just r) (Just m) = genPrintTy t (Just (TupE [VarE r,VarE m])) 
genPrintTupleInner t Nothing Nothing   = genPrintTy t Nothing



genPrintExp :: Exp -> Maybe Exp -> Q Exp
genPrintExp e@(LitE (CharL c)) _ = [| addString [$(return e)] |]
genPrintExp e@(LitE (StringL s)) _ = [| addString $(return e) |]
genPrintExp exp        _ = [| addString (show $(return exp)) |]

genPrintTycon :: UString -> Maybe Exp -> Q Exp
genPrintTycon c Nothing = undefined
genPrintTycon c (Just rm) = return (VarE (mkTyPrinterName c) `AppE` rm)

genPrintTyVar :: LString -> Maybe Exp -> Q Exp
genPrintTyVar v (Just rm) = return (VarE (mkTyPrinterVarName v) `AppE` rm)


genPrintTermCond = undefined



  






{-
printE' :: (PadsTy, Exp, Exp) -> Q Exp
printE' (ty, repE, mdE) = case ty of
  Plit  PS.EorL        -> return       (VarE(getPrintFLName "PeorLit"))                           
  Plit  PS.EofL        -> return       (VarE(getPrintFLName "PeofLit"))                           
  Plit  PS.VoidL       -> return       (VarE(getPrintFLName "PvoidLit"))            
  Plit  l              -> return (AppE (VarE 'litPrint) (litToExp l))
  Pname p_name   -> return (AppE  (VarE (getPrintFLName p_name))  (TupE [repE, mdE]))
  Ptuple ptys    -> printTuple ptys repE mdE 
  Pline ty'      -> printLine (ty', repE, mdE)
  Papp ty' argE  -> printApp (ty', argE, repE, mdE)
  Ptrans tySrc tyDst trans    -> printTrans(tySrc,tyDst,trans,repE,mdE)
  Ptypedef pat ty pred  -> printTypeDef (ty, repE, mdE)
  Precord recName fieldInfo -> printRecord (mkRepName recName) fieldInfo repE mdE
  Punion  unionName fieldInfo -> printUnion (mkRepName unionName) fieldInfo repE mdE
  Pmaybe ty -> printMaybe ty repE mdE
  Plist elemTy optSepTy optTermCond -> genPrintList elemTy optSepTy optTermCond repE mdE
  Ptry ty -> return (VarE('printNothing))
  Pswitch unionName whichE patBranches -> printUnion (mkRepName unionName) (map snd patBranches) repE mdE

-}



------------------------------------
-- Name manipulation functions 
------------------------------------

-- Naming types, and accessing the names of types

mkRepName str = mkName str

mkMDName str = case M.lookup str baseTypesMap of
         Nothing -> mkName (str ++ "_md")
         Just _ -> ''Base_md         


mkIMDName name = mkName (name ++ "_imd")


mkRepNameTQ str = return (ConT (mkRepName str))
mkMDNameTQ str = return (ConT (mkMDName str))

mkMDVarName name = mkName (name ++ "_md")


-- Naming fields and constructors

mkFieldName str   = mkName str
mkFieldMDName str = mkName (str++"_md")



mkConstrName   str  = mkName str
mkConstrIMDName str = mkName (str++"_imd")
mkfnMDName str      = mkName (strToLower str ++ "_md")


-- Naming Parsers

mkTyParserName  str = mkName ((strToLower str) ++ "_parseM")
mkTyParserSName str = mkName ((strToLower str) ++ "_parseS")

mkVarParserName str = mkName (str ++ "__p")


-- Naming Printers

mkTyPrinterName str    = mkName ((strToLower str) ++ "_printFL")
mkTyPrinterVarName str = mkName (str ++ "__pr")


 
























































------------------------------------
-- Old Stuff 
------------------------------------



{-
getBranchMDNameU str = mkName ((strToUpper str)++"_md")
getBranchNameU str = mkName (strToUpper str)

getBranchMDNameL str = mkName ((strToLower str)++"_md")
getBranchNameL   str = mkName  (strToLower str)
-}

{-

mkPadsInstance parse_name print_name ty_name md_ty mpat_info = 
  let (inst, parsePP, printFL) = case mpat_info of
                          Nothing -> (AppT (AppT (ConT ''Pads) (ConT ty_name)) md_ty,   -- Pads RepTy MDTy
                                      mkName "parsePP",
                                      mkName "printFL")
                          Just (p,arg_ty) -> 
                                     (AppT 
                                        (AppT (AppT (ConT ''Pads1) arg_ty) (ConT ty_name)) 
                                        md_ty,   -- Pads Arg RepTy MDTy
                                      mkName "parsePP1",
                                      mkName "printFL1")
      parsePP_method = ValD (VarP parsePP) (NormalB (VarE parse_name)) []
      printFL_method = ValD (VarP printFL) (NormalB (VarE print_name)) []
  in [InstanceD [] inst [parsePP_method, printFL_method]]

   
-}


--   printFL :: [Dec]           <- genPadsPrintFL p_name print_name    ty_name md_ty_name padsTy arg_info_opt

{-
accumulator: String -> String
when apply to a string, it appends a string on the front of whatever you apply it to

let p = \x . "hello world" ++ x
let q = \y -> "holiday" ++ y

new accumulator is: p . q
left-linear tree of compositions
apply accumulator to end of string
associativity for composition starts building string up over one one pass.

define own datatype
 binary tree datatype w/strings at the leaves; want to keep it relatively balanced, an AVL tree (maybe in library)
 put strings on the end, then you could start putting strings 

pair of lists to encode a queue
-}

{-

genPadsPrintFL :: String -> Name ->    Name ->  Name -> PadsTy -> Maybe (Pat, Type) -> Q [Dec]
genPadsPrintFL    p_name    print_name rep_name pd_name padsTy mpat_info = do 
   core_bodyE <- printE rep_name pd_name padsTy
   let core_ty = arrowTy (AppT (AppT (TupleT 2) (ConT rep_name)) (ConT pd_name)) (ConT (mkName "FList"))
   let (bodyE,ty) = case mpat_info of
                     Nothing -> (core_bodyE, core_ty)
                     Just (pat,pat_ty) -> ( LamE [pat] core_bodyE,
                                            arrowTy pat_ty core_ty)
   let sigD = SigD print_name ty
   let funD = ValD (VarP print_name) (NormalB bodyE) []
   return [sigD, funD]

printE :: Name -> Name -> PadsTy -> Q Exp
printE repN mdN ty = do
   repName     <- genRepName 
   mdName      <- genMdName 
   let (repE,repP) = genPE repName
   let (mdE, mdP)  = genPE mdName
   let frepP       = wrapRepP repN ty repP 
   rhsE        <- printE' (ty, repE, mdE)
   let printFun = LamE [TupP [frepP,mdP]] rhsE
   return printFun


wrapRepP :: Name -> PadsTy -> Pat -> Pat
wrapRepP repN ty repP = ConP repN [repP]


printE' :: (PadsTy, Exp, Exp) -> Q Exp
printE' (ty, repE, mdE) = case ty of
  Plit  PS.EorL        -> return       (VarE(getPrintFLName "PeorLit"))                           
  Plit  PS.EofL        -> return       (VarE(getPrintFLName "PeofLit"))                           
  Plit  PS.VoidL       -> return       (VarE(getPrintFLName "PvoidLit"))            
  Plit  l              -> return (AppE (VarE 'litPrint) (litToExp l))
  Pname p_name   -> return (AppE  (VarE (getPrintFLName p_name))  (TupE [repE, mdE]))
  Ptuple ptys    -> printTuple ptys repE mdE 
  Pline ty'      -> printLine (ty', repE, mdE)
  Papp ty' argE  -> printApp (ty', argE, repE, mdE)
  Ptrans tySrc tyDst trans    -> printTrans(tySrc,tyDst,trans,repE,mdE)
  Ptypedef pat ty pred  -> printTypeDef (ty, repE, mdE)
  Precord recName fieldInfo -> printRecord (mkRepName recName) fieldInfo repE mdE
  Punion  unionName fieldInfo -> printUnion (mkRepName unionName) fieldInfo repE mdE
  Pmaybe ty -> printMaybe ty repE mdE
  Plist elemTy optSepTy optTermCond -> genPrintList elemTy optSepTy optTermCond repE mdE
  Ptry ty -> return (VarE('printNothing))
  Pswitch unionName whichE patBranches -> printUnion (mkRepName unionName) (map snd patBranches) repE mdE

genPrintList :: PadsTy -> (Maybe PadsTy) -> (Maybe TermCond) -> Exp -> Exp -> Q Exp
genPrintList ty sepOpt termCondOpt repE mdE = do 
  (elemRepE, elemRepP) <- doGenPE "elemrep"
  (elemMDE,  elemMDP)  <- doGenPE "elemmd"
  parseElemE <- printE' (ty, elemRepE, elemMDE)
  let parseElemFnE = LamE [TupP [elemRepP, elemMDP]] parseElemE
  sepElemE <- case sepOpt of 
                Nothing -> return (VarE 'printNothing)
                Just ty -> printE' (ty, TupE [], TupE [])
  termElemE <- case termCondOpt of
                Nothing -> return (VarE 'printNothing)
                Just (LengthTC _) -> return (VarE 'printNothing)
                Just (TyTC (Ptry _)) -> return (VarE 'printNothing)
                Just (TyTC (Ptuple [Ptry _])) -> return (VarE 'printNothing)
                Just (TyTC termTy) -> printE' (termTy, TupE [], TupE [])
  return (AppE (AppE (AppE (AppE (VarE 'printList) (TupE [repE, mdE])) parseElemFnE) sepElemE) termElemE)


printUnion :: Name -> [FieldInfo] -> Exp -> Exp -> Q Exp
printUnion ty_name branches repE mdE = do
  matches <- printBranches branches
  let caseE = CaseE (TupE [repE,mdE]) matches
  return caseE

printBranches :: [FieldInfo] -> Q [Match]
printBranches branches = mapM printBranch branches

printBranch :: (Maybe String, PadsTy, Maybe Exp) -> Q Match
printBranch (Just str, branchTy, pred) = do
  (repE, repP) <- doGenPE "rep"
  (mdE,  mdP)  <- doGenPE "md"
  bodyE <- printE' (branchTy, repE, mdE)
  let caseBodyB = NormalB bodyE
  let repPatArg = case branchTy of {Plit _ -> [] ; _ -> [repP]}
  let repPat = ConP (getBranchNameU str) repPatArg
  let mdPat =  TupP[WildP, ConP (getBranchMDNameU str) [mdP]]
  let casePat = TupP [repPat, mdPat]
  let match = Match casePat caseBodyB []
  return match


printTypeDef :: (PadsTy, Exp, Exp) -> Q Exp
printTypeDef (pty, repE, mdE) = printE' (pty, repE, AppE (VarE 'snd) mdE)

printTrans :: (PadsTy, PadsTy, Exp, Exp, Exp) -> Q Exp
printTrans (tySrc, tyDst, transE, repE, mdE) = do 
  (tmpRepE, tmpRepP) <- doGenPE "rep"
  (tmpMdE,  tmpMdP) <- doGenPE "md"
  let toDiskE = AppE (VarE 'snd) transE
  let    cvtE = AppE toDiskE (TupE [repE, mdE])
  printBodyE <- printE' (tySrc, tmpRepE, tmpMdE)
  let letPat = ValD (TupP [tmpRepP, tmpMdP]) (NormalB cvtE) []
  return (LetE [letPat] printBodyE)


printApp :: (PadsTy, Exp, Exp, Exp) -> Q Exp
printApp (ty, argE, repE, mdE) = case ty of
  Pname p_name   -> return (AppE (AppE  (VarE (getPrintFLName p_name))  argE) (TupE [repE, mdE]))


printRecord :: Name -> [FieldInfo] -> Exp -> Exp -> Q Exp
printRecord recName fields repE mdE = do 
  let (repEs, repPs) = getPEforFields getBranchNameL fields
  let (mdEs,  mdPs)  = getPEforFields getBranchMDNameL fields
  let ptys = map (\(n,ty,p) -> ty) fields
  let ty_rep_mds = zip3 ptys repEs mdEs
  expE <- mapM printE' ty_rep_mds
  let printItemsE = ListE expE
  let caseBody = NormalB (AppE (VarE 'concatFL) printItemsE)
  let mdPat  = TupP[WildP, RecP (mkInnerMDName recName) mdPs]
  let repPat = RecP recName repPs
  let casePat = TupP [repPat, mdPat]
  let match = Match casePat caseBody []
  let caseE = CaseE (TupE [repE,mdE]) [match]
  return caseE

getPEforField :: (String -> Name) -> (Maybe String, PadsTy, Maybe Exp) -> (Exp, Maybe FieldPat)
getPEforField mkFieldNm (nameOpt, pty, optPred) = case nameOpt of
  Nothing -> (TupE [], Nothing) 
  Just str -> let (varE, varP) = genPE (mkFieldNm str)
              in (varE, Just (mkFieldNm str, varP))

getPEforFields :: (String -> Name) -> [(Maybe String, PadsTy, Maybe Exp)] ->  ([Exp], [FieldPat])
getPEforFields mkFieldNm fields = 
  let eps =  map (getPEforField mkFieldNm) fields
      (es, pOpts) = List.unzip eps
      ps = Maybe.catMaybes pOpts
  in (es, ps)





-}




