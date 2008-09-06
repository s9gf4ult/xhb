-- Generates the data types for a particular X module.
-- Also includes class instance declarations for those types
-- when appropriate.

module Generate where

import Generate.Build
import Generate.Monad
import Generate.Facts

import Data.XCB

import HaskellCombinators
import Language.Haskell.Syntax

import Control.Monad.Reader
import qualified Data.List as L
import Control.Applicative

import Data.Maybe
import Data.Function

-- | Converts X modules to Haskell modules declaring the
-- appropriate data types.
--
-- All modules which are involved in cross-module
-- qualified types must be converted at the same time.
--
-- All modules which are involved in importing each
-- other must be converted at the same time.
toHsModules :: [XHeader] -> [HsModule]
toHsModules xs = map (toHsModule xs) xs

-- | Performs a single step of the 'toHsModules' conversion.
toHsModule :: [XHeader] -> XHeader -> HsModule
toHsModule xs xhd =
    let rdata = ReaderData xhd xs
    in runGenerate rdata typesModule


typesModule :: Generate HsModule
typesModule = do
  newModule <- newXhbTypesModule <$> (currentName >>= fancyName)
  
  f <- appMany <$> sequence
       [ processDeclarations
       ]
  
  return $ f newModule

-- do something per XDecl in the current module, in order
processDeclarations :: Generate (HsModule -> HsModule)
processDeclarations =
  appMany <$> (currentDeclarations >>= mapM xDecl)

-- |Converts a declaration to a modification on a Haskell module
xDecl :: XDecl -> Generate (HsModule -> HsModule)
xDecl (XidType name) = return $ appMany
  [ addDecl $
     simpleNewtype name "Xid" ["Eq","Ord","Show","Serialize","Deserialize","XidLike"]
  , exportTypeAbs name
  ]
xDecl (XidUnion name _fields) =
            -- Pretend it's a declaration of an Xid Type
            xDecl $ XidType name
xDecl (XStruct name fields) = appMany <$> sequence
  [ declareStruct name fields
  , return . addDecl $ declareSerStruct name fields
  , return . addDecl $ declareDeserStruct name fields
  , return $ exportType name
  ]
xDecl (XTypeDef name typ) = appMany <$> sequence
  [ addDecl <$> typeDecl name typ
  , return $ exportTypeAbs name
  ]
xDecl (XImport name) = xImport name
xDecl (XRequest name opcode fields resp) = appMany <$> sequence
  [ declareStruct name fields
  , return $ exportType name
  , addDecl <$> declareSerRequest name opcode fields
  , case resp of
      Nothing -> return id -- empty
      Just rFields -> 
         let rName = replyName name
         in appMany <$> sequence
                [ declareStruct rName rFields
                , return $ exportType rName
                , return . addDecl $ declareDeserReply rName rFields
                ]
  ]
xDecl (XEvent name opcode fields _) = appMany <$> sequence
  [ declareStruct name fields
  , return $ exportType name
  ]
xDecl (XError name opcode fields) = appMany <$> sequence
  [ declareStruct name fields
  , return $ exportType name
  ]
xDecl dec@(XEnum nm elems') =
  let elems = cleanEnum . fillEnum $ elems'
      typ = verifyEnum dec elems
  in return $ appMany
      [ addDecl $ declareEnumTycon nm elems
      , addDecl $ declareEnumInstance typ nm elems
      , exportType nm
      ]
xDecl (XUnion _ _) = return id -- Unions are currently unhandled
xDecl x = error $ "Pattern match failed in \"xDecl\" with argument:\n" ++ (show $ toDoc x)

-- | For an X enum, declares an instance of 'SimpleEnum' of 'BitEnum'
-- as appropriate.
declareEnumInstance :: EnumType -> Name -> [EnumElem] -> HsDecl
declareEnumInstance _typ _name [] = error $ "declareEnumInstance: " ++
                                    "Enum has no elements"
declareEnumInstance ETypeValue name els =
      mkInstDecl
      []
      (mkUnQName "SimpleEnum")
      [mkTyCon name]
      [HsFunBind (map toVal els)
      ,HsFunBind (map fromVal els)
      ]
  where toVal (EnumElem nm (Just (Value n)))
            = mkConsMatch "toValue" (name ++ nm) (mkNumLit n)
        fromVal (EnumElem nm (Just (Value n)))
            = mkLitMatch "fromValue" (HsInt $ fromIntegral n) (HsCon (mkUnQName (name ++ nm)))

declareEnumInstance ETypeBit name els =
       mkInstDecl
       []
       (mkUnQName "BitEnum")
       [mkTyCon name]
       [HsFunBind (map toBit els)
       ,HsFunBind (map fromBit els)
       ]
   where toBit (EnumElem nm (Just (Bit n)))
             = mkConsMatch "toBit" (name ++ nm) (mkNumLit n)
         fromBit (EnumElem nm (Just (Bit n)))
             = mkLitMatch "fromBit" (HsInt (fromIntegral n)) $ HsCon $ mkUnQName $ name++nm

-- | For an X enum, declares a Haskell data type.
declareEnumTycon :: Name -> [EnumElem] -> HsDecl
declareEnumTycon name elems =
            mkDataDecl
            []
            name
            []
            (map (mkEnumCon name) elems)
            [] -- derving

-- | For an element of an X enum, declares a clause in the Haskell data constructor
mkEnumCon :: Name -> EnumElem -> HsConDecl
mkEnumCon tyname (EnumElem name _) = mkCon (tyname ++ name) []


data EnumType = ETypeValue | ETypeBit | ETypeError
 deriving (Eq, Show, Enum, Bounded, Ord)

cleanEnum :: [EnumElem] -> [EnumElem]
cleanEnum xs =
  let containsBits = not . null $ justBits

      justBits = filter bitElem xs

      bitElem (EnumElem _ (Just (Bit {}))) = True
      bitElem _ = False

  in if containsBits
      then justBits
      else xs

-- | Throws an error if we're not prepared to generate code
-- for an X enum.
--
-- In particular, we disallow enums with both regular numbers
-- and bit-field numbers.
verifyEnum :: XDecl -> [EnumElem] -> EnumType
verifyEnum dec elems = case enumType elems of
        ETypeError -> enumTypPanic dec
        x -> x

-- | Returns the type of the enum elements.
-- An enum is either a 'Value' enum or a 'Bit' enum.
-- This is more strict than the xproto xml schema.
enumType :: [EnumElem] -> EnumType
enumType xs = case L.foldl' (flip go) Nothing xs of
                Nothing -> ETypeError
                Just x -> x
    where go x Nothing = return $ etyp x
          go _ jr@(Just ETypeError) = jr
          go x jr@(Just r) | etyp x == r = jr
          go _ _ = Just ETypeError

          etyp (EnumElem _ (Just (Value {}))) = ETypeValue
          etyp (EnumElem _ (Just (Bit {})))   = ETypeBit
          etyp _                       = ETypeError

enumTypPanic :: XDecl -> a
enumTypPanic dec = error $
                   ("Error in enum:\n\n" ++) $
                   show $ toDoc dec

-- |If an enum doesn't have defined values fill them in
fillEnum :: [EnumElem] -> [EnumElem]
fillEnum xs@((EnumElem _ Nothing):_) = map f $ zip xs [0..]
    where f (EnumElem name _, n) = EnumElem name (Just (Value n))
fillEnum x = x

-- | If the X module declares that it imports another X module,
-- this function imports the corresponding Haskell module.
--
-- Conflicting declarations are imported qualified.
-- Non-conflicted declarations are imported normally.
xImport :: String -> Generate (HsModule -> HsModule)
xImport str = do
  cur <- current
  impMod <- fromJust `liftM` lookupModule str -- bad error message
  let shared_types = (L.intersect `on` declaredTypes) cur impMod
      impName = typesModuleName $ modName impMod
  if null shared_types
   then return . addImport . mkImport $ impName
   else return $ appMany
    [ addImport $ mkHidingImport impName shared_types
    , addImport . mkQualImport $ impName
    ]

-- |A list of all of the types defined by a module.
declaredTypes :: XHeader -> [Name]
declaredTypes xhd =
    let decls = xheader_decls xhd

        tyName (XStruct name _) = return name
        tyName (XTypeDef name _) = return name
        tyName (XEvent name _ _ _) = return name
        tyName (XRequest name _ _ Nothing) = return name
        tyName (XRequest name _ _ _) = [name, replyName name]
        tyName (XidType name) = return name
        tyName (XidUnion name _) = return name
        tyName (XEnum name _) = return name
        tyName (XUnion name _) = return name
        tyName XImport{} = empty
        tyName (XError name _ _) = return name

    in concatMap tyName decls


-- | An X type declaration.  Re-written to a Haskell type declaration.
-- Cross-module lookups of qualified types are handled here.
typeDecl :: String -> Type -> Generate HsDecl
typeDecl nm tp = 
  mkTypeDecl nm [] <$> toHsType tp

-- | Given a type name and a list of X struct elements this declares
-- a Haskell data type.
declareStruct :: String -> [StructElem] -> Generate (HsModule -> HsModule)
declareStruct name fields = do
         selems <- selemsToRec fields
         fExprFields <- exprFields name fields
         return $ appMany
          [ addDecl $ mkDataDecl
             []
             name
             []
             [mkRCon (conPrefix name) (selems)]
             [mkUnQName "Show"]
          , fExprFields
          ]
    where selemsToRec :: [StructElem] -> Generate [(String,HsBangType)]
          selemsToRec xs = do
            ys <- embed $ mapAlt go xs
            return $ fromJust ys -- mapAlt never returns Nothing

          go :: StructElem -> ReaderT ReaderData Maybe (String, HsBangType)
          go (Pad {})      = empty
          go (List nm tp _) = 
              do hsType <- listType <$> toHsType tp
                 return $
                  (accessor nm name, HsUnBangedTy hsType)
              where listType = HsTyApp list_tycon
          go (SField nm tp) = do
              hsType <- toHsType tp
              return $ (accessor nm name, HsUnBangedTy hsType)
          go (ValueParam typ mname _lname) = do
            hsType <- toHsType typ
            return $
             let nme = valueParamName mname
                 vTyp = HsTyApp (mkTyCon "ValueParam") hsType
             in (accessor nme name, HsUnBangedTy $ vTyp)
  
          go (ExprField{}) = empty -- deal with these separately
          go selem = selemsToRecPanic selem

valueParamName :: Name -> Name
valueParamName mname = 
    let name = case nm of
                Nothing -> mname
                Just n -> reverse $ drop (n+1) $ rname
        rname = reverse mname
        nm = L.findIndex (== '_') rname
    in name

selemsToRecPanic :: StructElem -> a
selemsToRecPanic x = error $
                     ("I dont know what to do with struct elem: " ++) $
                     show $ toDoc x


-- | Some identifiers clash with Haskell key-words.
-- This function renames those that do.
mapIdents :: String -> String
mapIdents "data" = "data_"
mapIdents "type" = "type_"
mapIdents "class" = "class_"
mapIdents x = x

exprFields :: Name -> [StructElem] -> Generate (HsModule -> HsModule)
exprFields name elems = appMany <$> (sequence $ map go elems)
                        
    where go :: StructElem -> Generate (HsModule -> HsModule)
          go (ExprField nm tp expr) = do
            retTyp <- toHsType tp
            let funName = accessor nm name
                funTyp = HsTyFun (mkTyCon name) retTyp
                inVar = "x"
            
            return . appMany $
             [
                -- Type signature
               addDecl $ mkTypeSig funName [] funTyp
            
               -- function body
             , addDecl $ mkSimpleFun funName [mkPVar inVar] $ 
                mkExpr (Just (inVar, name)) expr

              -- export
             , exportVar funName
             ]
          go _ = return id


-- | Convert an 'Expression' to a Haskell expression.
--
-- The first argument is non-nothing when used in the context of
-- writing a deserialization function.  The first element of the pair
-- is the name of the variable which is being deserialized and the second
-- element is the name of the type being deserialized.
mkExpr :: Maybe (Name, Name) -> Expression -> HsExp
mkExpr _ (Value n) = mkNumLit n
mkExpr _ (Bit n) = mkNumLit $ 2^n
mkExpr (Just (rec, name)) (FieldRef field)
    = HsApp
      (mkVar $ accessor field name)
      (mkVar rec)
mkExpr Nothing (FieldRef field) = mkVar field
mkExpr rec (Op op lhs rhs) =
    let eLhs = mkExpr rec lhs
        eRhs = mkExpr rec rhs
    in HsParen $ HsApp (mkVar "fromIntegral") $ HsParen $ HsInfixApp eLhs (mkOp op) eRhs

mkOp :: Binop -> HsQOp
mkOp Add  = stringToQOpSymbol "+"
mkOp Sub  = stringToQOpSymbol "-"
mkOp Mult = stringToQOpSymbol "*"
mkOp Div  = stringToQOpSymbol "`div`"
mkOp And  = stringToQOpSymbol ".&."
mkOp RShift = HsQVarOp . UnQual . HsIdent $ "shiftR"

stringToQOpSymbol = HsQVarOp . UnQual . HsSymbol


----- Declaring serialize and deserialize instances

-- | Declare a instance of 'Deserialize' for an X struct
-- declaration.
declareDeserStruct :: Name -> [StructElem] -> HsDecl
declareDeserStruct name fields =
    mkInstDecl
      []
      (mkUnQName "Deserialize")
      [HsTyCon $ mkUnQName name]
      [deserFunc]
   where
     deserFunc :: HsDecl
     deserFunc = mkSimpleFun
                  "deserialize"
                  [mkPVar "bo"
                  ]
                 (HsDo $ deserIns fields ++ [returnIt name fields])

-- | Declare and instance of 'Deserialize' for a reply to an X request.
declareDeserReply :: Name -> [StructElem] -> HsDecl
declareDeserReply name fields =
    mkInstDecl
      []
      (mkUnQName "Deserialize")
      [HsTyCon $ mkUnQName name]
      [deserFunc]
   where
     deserFunc :: HsDecl
     deserFunc = mkSimpleFun
                 "deserialize"
                 [mkPVar "bo"]
                 (HsDo $ deserIns (doFields fields) ++ [declareLengthType, returnIt name fields])

     -- the same as the regular fields, except with more padding
     -- and the implicit length thrown in
     doFields (x1 : xs) = Pad 1 : x1 : Pad 2 : SField "length" (UnQualType "CARD32") : xs

     declareLengthType :: HsStmt
     declareLengthType = HsLetStmt [mkPatBind HsPWildCard $ mkVar "isCard32" `HsApp` mkVar "length"]

-- | Declare a statement in the 'do' block of the 'deserialize' function.
deserIns :: [StructElem] -> [HsStmt]
deserIns fields = mapMaybe go fields
 where
     go (Pad n) = return $ HsQualifier $ mkVar "skip" `HsApp` mkNumLit n 
     go (List nm _typ Nothing) = error "cannot deserialize list with no length"
     go (List nm _typ (Just exp))
         = return $ mkGenerator (mkPVar $ mapIdents nm) $ hsAppMany
           [mkVar "deserializeList"
           ,mkVar "bo"
           ,HsParen $ mkVar "fromIntegral" `HsApp` mkExpr Nothing exp
           ]

     go (SField nm _typ) = return $ mkGenerator (mkPVar $ mapIdents nm) $
             mkVar "deserialize" `HsApp` mkVar "bo"
     go ExprField{} = empty
     go v@(ValueParam _ vname _) = let nm = mapIdents $ valueParamName vname
                         in return $ mkGenerator (mkPVar nm) $
                            mkVar "deserialize" `HsApp` mkVar "bo"
     go n = error $ "Pattern match fail in deserIns.go with: " ++ show n

-- | Return and construct the deserialized value.
returnIt :: Name -> [StructElem] -> HsStmt
returnIt name fields = HsQualifier $ mkVar "return" `HsApp` HsParen (cons name fields)

-- | Create and fill-in the constructor for the deserialized value.
cons :: Name -> [StructElem] -> HsExp
cons name fields = hsAppMany $
       mkConExp (conPrefix name) : mapMaybe (liftM (mkVar . mapIdents) . fieldName) fields

fieldName :: StructElem -> Maybe Name
fieldName Pad{} = empty
fieldName (List name _ _) = Just name
fieldName (SField name _) = Just name
fieldName ExprField{} = empty -- has a name, but we don't want it
fieldName (ValueParam _ name _) = return $ valueParamName name


-- | Declare an instance of 'Serialize' for an X struct.
declareSerStruct :: Name -> [StructElem] -> HsDecl
declareSerStruct name fields =
    mkInstDecl
      []
      (mkUnQName "Serialize")
      [HsTyCon $ mkUnQName name]
      [serializeFunc,
       sizeFunc
      ]
  where
    sizeFunc :: HsDecl
    sizeFunc = mkSimpleFun "size"
                [mkPVar "x"]
                (L.foldl1' addExp $ mapMaybe (toFieldSize name) fields)


    serializeFunc = mkSimpleFun "serialize"
          [mkPVar "bo"
          ,mkPVar "x"]
          (HsDo $ map HsQualifier $ mapMaybe (serField name) fields)

-- | Declare an instance of "ExtensionRequest".
-- May not be called when generating code for a core
-- module.
declareExtRequest :: Name -> Int -> [StructElem] -> Generate HsDecl
declareExtRequest name opCode fields = do
        extName <- (fromJust . xheader_xname) `liftM` current
        return $
         mkInstDecl
         []
         (mkUnQName "ExtensionRequest")
         [HsTyCon $ mkUnQName name]
         [extensionIdFunc extName
         ,serializeReqFunc
         ]
 where

   serActions = mapMaybe (serField name) fields
   sizeActions = mapMaybe (toFieldSize name) fields

   extensionIdFunc :: Name -> HsDecl
   extensionIdFunc name =
       mkSimpleFun "extensionId"
        [HsPWildCard]
        (HsLit . HsString $  name)


   serializeReqFunc :: HsDecl
   serializeReqFunc = mkSimpleFun "serializeRequest"
        [mkPVar "x"
        ,mkPVar "extOpCode"
        ,mkPVar "bo"
        ]
        (HsDo actions)

   actions :: [HsStmt]
   actions = (HsQualifier $ putIntExp $ mkVar "extOpCode")
           : (HsQualifier $ putIntExp $ mkNumLit opCode)
           : computeSize
           : HsQualifier putSize
           : map HsQualifier serActions
           ++ map HsQualifier [putPadding]

   computeSize :: HsStmt
   computeSize = mkLetStmt (mkPVar "size__") sizeCalc

   sizeCalc :: HsExp
   sizeCalc = L.foldl1' addExp $ mkNumLit 4 : sizeActions

   putSize = HsApp serializeExp $ HsParen $ mkAsExp sizeExp $ mkTyCon "INT16"

   sizeExp = HsApp (mkVar "convertBytesToRequestSize") $
             mkVar "size__"

   putPadding = HsApp (mkVar "putSkip") $ HsParen $
                HsApp (mkVar "requiredPadding") $
                mkVar "size__"


putIntExp exp = mkVar "putWord8" `HsApp` exp
serializeExp = mkVar "serialize" `HsApp` mkVar "bo"

-- | Declare and instance of 'Serialize' for a request.
declareSerRequest :: Name -> Int -> [StructElem] -> Generate HsDecl
declareSerRequest name opCode fields = do
  ext <- isExtension
  if ext
   then
      -- extension request case:
      -- declare instance of "ExtensionRequest"
      -- instead of "Serialize"
      declareExtRequest name opCode fields
   else
      -- Core request
      return $
        mkInstDecl
        []
        (mkUnQName "Serialize")
        [HsTyCon $ mkUnQName name]
        [serializeFunc,
         sizeFunc
        ]
  where
    sizeFunc :: HsDecl
    sizeFunc = mkSimpleFun "size"
                [mkPVar "x"]
                (L.foldl1' addExp sizeExps)

    sizeExps :: [HsExp]
    sizeExps = case serActions of
                 [] -> [mkNumLit 4]
                 _ -> mkNumLit 3 : mapMaybe (toFieldSize name) fields
    

    serializeFunc = mkSimpleFun "serialize"
           [mkPVar "bo"
           ,mkPVar "x"]
           (HsDo $ map HsQualifier $ leadingActs ++ trailingActs)

    serActions = mapMaybe (serField name) fields

    leadingActs = [putIntExp $ mkNumLit opCode,firstAction serActions]
    trailingActs = (putSize : drop 1 serActions) ++ [putPadding]

    firstAction [] = mkVar "putSkip" `HsApp` mkNumLit 1
    firstAction (x:_) = x

    -- 'putSize', 'sizeExp' and 'putPadding' are similar to
    -- but not quite the same as the functions for extension
    -- reqeusts above.
    putSize = HsApp serializeExp $ HsParen $ mkAsExp sizeExp $ mkTyCon "INT16"

    sizeExp = HsApp (mkVar "convertBytesToRequestSize") $
                HsParen $ mkVar "size" `HsApp` mkVar "x"

    putPadding = HsApp (mkVar "putSkip") $ HsParen $
                 HsApp (mkVar "requiredPadding") $  HsParen $
                 mkVar "size" `HsApp` mkVar "x"

-- | A statement in the "do" block for the 'serialize' function.
serField :: Name -> StructElem -> Maybe HsExp
serField _ (Pad n) -- "putSkip n"
        = return $ mkVar "putSkip" `HsApp` mkNumLit n
serField name (List lname _typ _expr) -- serializeList bo <list>
        = return $ 
          HsApp (mkVar "serializeList" `HsApp` mkVar "bo") $ HsParen $
          accessField name lname
serField name (SField fname _typ) -- serialize bo <field>
        = return $ HsApp (mkVar "serialize" `HsApp` mkVar "bo") $ HsParen $
          accessField name fname
serField name (ExprField fname typ _exp)  = serField name (SField fname typ)
serField name (ValueParam _ mname _) -- serialize bo <field>
        = return $ HsApp (mkVar "serialize" `HsApp` mkVar "bo") $ HsParen $
          accessField name $ valueParamName mname

addExp :: HsExp -> HsExp -> HsExp
addExp = expBinop "+"

expBinop op lhs rhs = HsInfixApp lhs (HsQVarOp . UnQual $ HsSymbol op) rhs

accessField name fieldName =
        mkVar (accessor fieldName name) `HsApp` mkVar "x"

sizeOfMember name fname = (mkVar "size" `HsApp`) $ HsParen $
                           accessField name fname

toFieldSize :: Name -> StructElem -> Maybe HsExp
toFieldSize _ (Pad n) = return $ mkNumLit n
toFieldSize name (List lname typ _expr) = return $
        (mkVar "sum" `HsApp`) $ HsParen $
        ((mkVar "map" `HsApp` mkVar "size") `HsApp`) $ HsParen $
        accessField name lname
toFieldSize name (SField fname _typ) = return $ sizeOfMember name fname
toFieldSize name (ExprField fname ftyp _) = toFieldSize name (SField fname ftyp)
toFieldSize name (ValueParam _ vname _) = return $
                sizeOfMember name . valueParamName $ vname

-- |Defines a newtype declaration.
simpleNewtype :: String   -- typename
              -> String   -- wrapped type (unqualified)
              -> [String] -- derived typeclass instances
              -> HsDecl
simpleNewtype name typ cls =
    mkNewtype
     []
     name
     []
     (mkCon (conPrefix name) [HsUnBangedTy . HsTyCon $ mkUnQName typ])
     (map (UnQual . HsIdent) cls)

-- |Export the named type without exporting constructors.
-- Should be usable for type synonyms as well.
exportTypeAbs :: String -> (HsModule -> HsModule)
exportTypeAbs = addExport . mkExportAbs

-- |Export the named type/thing non-abstractly
exportType :: String -> (HsModule -> HsModule)
exportType = addExport . mkExportAll

-- |Export the named variable
exportVar :: String -> (HsModule -> HsModule)
exportVar = addExport . HsEVar . mkUnQName

-- |Like mapMaybe, but for any Alternative.
-- Never returns 'empty', instead returns 'pure []'
mapAlt :: Alternative f => (a -> f b) -> [a] -> f [b]
mapAlt f xs = go xs
 where go [] = pure []
       go (y:ys) = pure (:) <*> f y <*> go ys
               <|> go ys

embed :: Monad m => ReaderT r m a -> Reader r (m a)
embed m = Reader $ \r -> runReaderT m r

