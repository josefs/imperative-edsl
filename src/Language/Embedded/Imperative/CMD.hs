{-# LANGUAGE CPP #-}

-- | Imperative commands

module Language.Embedded.Imperative.CMD where
  -- TODO There's probably no need to export the stuff under "Running commands"



import Data.Array.IO
import Data.Char (isSpace)
import Data.Int
import Data.IORef
import Data.Typeable
import Data.Word
import System.IO (IOMode (..))
import qualified System.IO as IO
import Text.Printf (PrintfArg)
import qualified Text.Printf as Printf

#if __GLASGOW_HASKELL__ < 708
import Data.Proxy
#endif

import Control.Monad.Operational.Compositional
import Data.TypePredicates
import Language.Embedded.Expression
import qualified Language.C.Syntax as C



--------------------------------------------------------------------------------
-- * References
--------------------------------------------------------------------------------

-- | Mutable reference
data Ref a
    = RefComp VarId
    | RefEval (IORef a)
  deriving Typeable

-- | Commands for mutable references
data RefCMD exp (prog :: * -> *) a
  where
    NewRef  :: VarPred exp a => RefCMD exp prog (Ref a)
    InitRef :: VarPred exp a => exp a -> RefCMD exp prog (Ref a)
    GetRef  :: VarPred exp a => Ref a -> RefCMD exp prog (exp a)
    SetRef  :: VarPred exp a => Ref a -> exp a -> RefCMD exp prog ()
      -- `VarPred` for `SetRef` is not needed for code generation, but it can be useful when
      -- interpreting with a dynamically typed store. `VarPred` can then be used to supply a
      -- `Typeable` dictionary for casting.
#if  __GLASGOW_HASKELL__>=708
  deriving Typeable
#endif

instance HFunctor (RefCMD exp)
  where
    hfmap _ NewRef       = NewRef
    hfmap _ (InitRef a)  = InitRef a
    hfmap _ (GetRef r)   = GetRef r
    hfmap _ (SetRef r a) = SetRef r a

instance CompExp exp => DryInterp (RefCMD exp)
  where
    dryInterp NewRef       = liftM RefComp fresh
    dryInterp (InitRef _)  = liftM RefComp fresh
    dryInterp (GetRef _)   = liftM varExp fresh
    dryInterp (SetRef _ _) = return ()

type instance IExp (RefCMD e)       = e
type instance IExp (RefCMD e :+: i) = e



--------------------------------------------------------------------------------
-- * Arrays
--------------------------------------------------------------------------------

-- | Mutable array
data Arr n a
    = ArrComp String
    | ArrEval (IOArray n a)
  deriving Typeable

-- | Commands for mutable arrays
data ArrCMD exp (prog :: * -> *) a
  where
    NewArr :: (VarPred exp a, VarPred exp n, Integral n, Ix n) => exp n -> ArrCMD exp prog (Arr n a)
    GetArr :: (VarPred exp a, Integral n, Ix n)                => exp n -> Arr n a -> ArrCMD exp prog (exp a)
    SetArr :: (Integral n, Ix n)                               => exp n -> exp a -> Arr n a -> ArrCMD exp prog ()
#if  __GLASGOW_HASKELL__>=708
  deriving Typeable
#endif

instance HFunctor (ArrCMD exp)
  where
    hfmap _ (NewArr n)       = NewArr n
    hfmap _ (GetArr i arr)   = GetArr i arr
    hfmap _ (SetArr i a arr) = SetArr i a arr

instance CompExp exp => DryInterp (ArrCMD exp)
  where
    dryInterp (NewArr _)   = liftM ArrComp $ freshStr "a"
    dryInterp (GetArr _ _)   = liftM varExp fresh
    dryInterp (SetArr _ _ _) = return ()

type instance IExp (ArrCMD e)       = e
type instance IExp (ArrCMD e :+: i) = e



--------------------------------------------------------------------------------
-- * Control flow
--------------------------------------------------------------------------------

data ControlCMD exp prog a
  where
    If    :: exp Bool -> prog () -> prog () -> ControlCMD exp prog ()
    While :: prog (exp Bool) -> prog () -> ControlCMD exp prog ()
    For   :: (VarPred exp n, Integral n) =>
             exp n -> exp n -> (exp n -> prog ()) -> ControlCMD exp prog ()
    Break :: ControlCMD exp prog ()

instance HFunctor (ControlCMD exp)
  where
    hfmap g (If c t f)        = If c (g t) (g f)
    hfmap g (While cont body) = While (g cont) (g body)
    hfmap g (For lo hi body)  = For lo hi (g . body)
    hfmap _ Break             = Break

instance DryInterp (ControlCMD exp)
  where
    dryInterp (If _ _ _)  = return ()
    dryInterp (While _ _) = return ()
    dryInterp (For _ _ _) = return ()
    dryInterp Break       = return ()

type instance IExp (ControlCMD e)       = e
type instance IExp (ControlCMD e :+: i) = e



--------------------------------------------------------------------------------
-- * File handling
--------------------------------------------------------------------------------

-- | File handle
data Handle
    = HandleComp String
    | HandleEval IO.Handle
  deriving Typeable

-- | Handle to stdin
stdin :: Handle
stdin = HandleComp "stdin"

-- | Handle to stdout
stdout :: Handle
stdout = HandleComp "stdout"

-- | Values that can be printed\/scanned using @printf@\/@scanf@
class (Typeable a, Read a, PrintfArg a) => Formattable a
  where
    formatSpecifier :: Proxy a -> String

instance Formattable Int    where formatSpecifier _ = "%d"
instance Formattable Int8   where formatSpecifier _ = "%d"
instance Formattable Int16  where formatSpecifier _ = "%d"
instance Formattable Int32  where formatSpecifier _ = "%d"
instance Formattable Int64  where formatSpecifier _ = "%d"
instance Formattable Word   where formatSpecifier _ = "%u"
instance Formattable Word8  where formatSpecifier _ = "%u"
instance Formattable Word16 where formatSpecifier _ = "%u"
instance Formattable Word32 where formatSpecifier _ = "%u"
instance Formattable Word64 where formatSpecifier _ = "%u"
instance Formattable Float  where formatSpecifier _ = "%f"
instance Formattable Double where formatSpecifier _ = "%f"

data FileCMD exp (prog :: * -> *) a
  where
    FOpen   :: FilePath -> IOMode                           -> FileCMD exp prog Handle
    FClose  :: Handle                                       -> FileCMD exp prog ()
    FEof    :: VarPred exp Bool => Handle                   -> FileCMD exp prog (exp Bool)
    FPrintf :: Handle -> String -> [FunArg Formattable exp] -> FileCMD exp prog ()
    FGet    :: (Formattable a, VarPred exp a) => Handle     -> FileCMD exp prog (exp a)

instance HFunctor (FileCMD exp)
  where
    hfmap _ (FOpen file mode)     = FOpen file mode
    hfmap _ (FClose hdl)          = FClose hdl
    hfmap _ (FPrintf hdl form as) = FPrintf hdl form as
    hfmap _ (FGet hdl)            = FGet hdl
    hfmap _ (FEof hdl)            = FEof hdl

instance CompExp exp => DryInterp (FileCMD exp)
  where
    dryInterp (FOpen _ _)     = liftM HandleComp $ freshStr "h"
    dryInterp (FClose _)      = return ()
    dryInterp (FPrintf _ _ _) = return ()
    dryInterp (FGet _)        = liftM varExp fresh
    dryInterp (FEof _)        = liftM varExp fresh

type instance IExp (FileCMD e)       = e
type instance IExp (FileCMD e :+: i) = e



--------------------------------------------------------------------------------
-- * Abstract objects
--------------------------------------------------------------------------------

data Object = Object
    { objectType :: String
    , objectId   :: String
    }
  deriving (Eq, Show, Ord, Typeable)

data ObjectCMD (prog :: * -> *) a
  where
    NewObject
        :: String  -- Type
        -> ObjectCMD prog Object

instance HFunctor ObjectCMD
  where
    hfmap _ (NewObject t) = NewObject t

instance DryInterp ObjectCMD
  where
    dryInterp (NewObject t) = liftM (Object t) $ freshStr "obj"

--------------------------------------------------------------------------------
-- * External function calls
--------------------------------------------------------------------------------

-- | External function arguments
data FunArg pred exp
  where
    -- Expression argument
    ValArg :: pred a => exp a -> FunArg pred exp
    -- Reference argument, passed by reference
    RefArg :: (pred a, Typeable a) => Ref a -> FunArg pred exp
    -- Array argument
    ArrArg :: (pred a, Typeable a) => Arr n a -> FunArg pred exp
    -- Object argument
    ObjArg :: Object -> FunArg pred exp
    -- Object address argument (address of the object pointer)
    ObjAddrArg :: Object -> FunArg pred exp
    -- String literal argument
    StrArg :: String -> FunArg pred exp

-- | Cast the argument predicate to 'Any'
anyArg :: FunArg pred exp -> FunArg Any exp
anyArg (ValArg a)     = ValArg a
anyArg (RefArg r)     = RefArg r
anyArg (ArrArg a)     = ArrArg a
anyArg (ObjArg o)     = ObjArg o
anyArg (ObjAddrArg o) = ObjAddrArg o
anyArg (StrArg s)     = StrArg s

data CallCMD exp (prog :: * -> *) a
  where
    AddInclude    :: String       -> CallCMD exp prog ()
    AddDefinition :: C.Definition -> CallCMD exp prog ()
    AddExternFun  :: VarPred exp res
                  => String
                  -> proxy (exp res)
                  -> [FunArg (VarPred exp) exp]
                  -> CallCMD exp prog ()
    AddExternProc :: String -> [FunArg (VarPred exp) exp] -> CallCMD exp prog ()
    CallFun       :: VarPred exp a => String -> [FunArg Any exp] -> CallCMD exp prog (exp a)
    CallProc      ::                  String -> [FunArg Any exp] -> CallCMD exp prog ()

instance HFunctor (CallCMD exp)
  where
    hfmap _ (AddInclude incl)           = AddInclude incl
    hfmap _ (AddDefinition def)         = AddDefinition def
    hfmap _ (AddExternFun fun res args) = AddExternFun fun res args
    hfmap _ (AddExternProc proc args)   = AddExternProc proc args
    hfmap _ (CallFun fun args)          = CallFun fun args
    hfmap _ (CallProc proc args)        = CallProc proc args

instance CompExp exp => DryInterp (CallCMD exp)
  where
    dryInterp (AddInclude _)       = return ()
    dryInterp (AddDefinition _)    = return ()
    dryInterp (AddExternFun _ _ _) = return ()
    dryInterp (AddExternProc _ _)  = return ()
    dryInterp (CallFun _ _)        = liftM varExp fresh
    dryInterp (CallProc _ _)       = return ()

type instance IExp (CallCMD e)       = e
type instance IExp (CallCMD e :+: i) = e



--------------------------------------------------------------------------------
-- * Running commands
--------------------------------------------------------------------------------

runRefCMD :: forall exp prog a . EvalExp exp => RefCMD exp prog a -> IO a
runRefCMD (InitRef a)                       = fmap RefEval $ newIORef $ evalExp a
runRefCMD NewRef                            = fmap RefEval $ newIORef $ error "reading uninitialized reference"
runRefCMD (SetRef (RefEval r) a)            = writeIORef r $! evalExp a
runRefCMD (GetRef (RefEval (r :: IORef b))) = fmap litExp $ readIORef r

runArrCMD :: EvalExp exp => ArrCMD exp prog a -> IO a
runArrCMD (NewArr n) = fmap ArrEval $ newArray_ (0, fromIntegral (evalExp n)-1)
runArrCMD (SetArr i a (ArrEval arr)) =
    writeArray arr (fromIntegral (evalExp i)) (evalExp a)
runArrCMD (GetArr i (ArrEval arr)) =
    fmap litExp $ readArray arr (fromIntegral (evalExp i))

runControlCMD :: EvalExp exp => ControlCMD exp IO a -> IO a
runControlCMD (If c t f)        = if evalExp c then t else f
runControlCMD (While cont body) = loop
  where loop = do
          c <- cont
          when (evalExp c) $ body >> loop
runControlCMD (For lo hi body) = loop (evalExp lo)
  where
    hi' = evalExp hi
    loop i
      | i <= hi'  = body (litExp i) >> loop (i+1)
      | otherwise = return ()
runControlCMD Break = error "cannot run programs involving break"

evalHandle :: Handle -> IO.Handle
evalHandle (HandleEval h)        = h
evalHandle (HandleComp "stdin")  = IO.stdin
evalHandle (HandleComp "stdout") = IO.stdout

readWord :: IO.Handle -> IO String
readWord h = do
    eof <- IO.hIsEOF h
    if eof
    then return ""
    else do
      c  <- IO.hGetChar h
      if isSpace c
      then return ""
      else do
        cs <- readWord h
        return (c:cs)

evalFPrintf :: EvalExp exp =>
    [FunArg Formattable exp] -> (forall r . Printf.HPrintfType r => r) -> IO ()
evalFPrintf []            pf = pf
evalFPrintf (ValArg a:as) pf = evalFPrintf as (pf $ evalExp a)

runFileCMD :: EvalExp exp => FileCMD exp IO a -> IO a
runFileCMD (FOpen file mode)              = fmap HandleEval $ IO.openFile file mode
runFileCMD (FClose (HandleEval h))        = IO.hClose h
runFileCMD (FClose (HandleComp "stdin"))  = return ()
runFileCMD (FClose (HandleComp "stdout")) = return ()
runFileCMD (FPrintf h format as)          = evalFPrintf as (Printf.hPrintf (evalHandle h) format)
runFileCMD (FGet h)   = do
    w <- readWord $ evalHandle h
    case reads w of
        [(f,"")] -> return $ litExp f
        _        -> error $ "fget: no parse (input " ++ show w ++ ")"
runFileCMD (FEof h) = fmap litExp $ IO.hIsEOF $ evalHandle h

runObjectCMD :: ObjectCMD IO a -> IO a
runObjectCMD (NewObject _) = error "cannot run programs involving newObject"

runCallCMD :: EvalExp exp => CallCMD exp IO a -> IO a
runCallCMD (AddInclude _)       = return ()
runCallCMD (AddDefinition _)    = return ()
runCallCMD (AddExternFun _ _ _) = return ()
runCallCMD (AddExternProc _ _)  = return ()
runCallCMD (CallFun _ _)        = error "cannot run programs involving callFun"
runCallCMD (CallProc _ _)       = error "cannot run programs involving callProc"

instance EvalExp exp => Interp (RefCMD exp)     IO where interp = runRefCMD
instance EvalExp exp => Interp (ArrCMD exp)     IO where interp = runArrCMD
instance EvalExp exp => Interp (ControlCMD exp) IO where interp = runControlCMD
instance EvalExp exp => Interp (FileCMD exp)    IO where interp = runFileCMD
instance                Interp ObjectCMD        IO where interp = runObjectCMD
instance EvalExp exp => Interp (CallCMD exp)    IO where interp = runCallCMD

