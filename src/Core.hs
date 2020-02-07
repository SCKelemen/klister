{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
module Core where

import Control.Lens hiding (elements)
import Control.Monad
import Data.Unique

import Alpha
import Phase
import ShortShow
import Signals
import Syntax


data SyntaxError a = SyntaxError
  { _syntaxErrorLocations :: [a]
  , _syntaxErrorMessage   :: a
  }
  deriving (Eq, Functor, Foldable, Show, Traversable)
makeLenses ''SyntaxError

newtype Var = Var Unique
  deriving (AlphaEq, Eq, Ord)

instance Show Var where
  show (Var i) = "(Var " ++ show (hashUnique i) ++ ")"

newtype MacroVar = MacroVar Unique
  deriving (AlphaEq, Eq, Ord)

instance Show MacroVar where
  show (MacroVar i) = "(MacroVar " ++ show (hashUnique i) ++ ")"

data Pattern
  = PatternIdentifier Ident Var
  | PatternEmpty
  | PatternCons Ident Var Ident Var
  | PatternList [(Ident, Var)]
  | PatternAny
  deriving (Eq, Show)
makePrisms ''Pattern

data ScopedIdent core = ScopedIdent
  { _scopedIdentIdentifier :: core
  , _scopedIdentScope      :: core
  }
  deriving (Eq, Functor, Foldable, Show, Traversable)
makeLenses ''ScopedIdent

data ScopedEmpty core = ScopedEmpty
  { _scopedEmptyScope :: core
  }
  deriving (Eq, Functor, Foldable, Show, Traversable)
makeLenses ''ScopedEmpty

data ScopedCons core = ScopedCons
  { _scopedConsHead  :: core
  , _scopedConsTail  :: core
  , _scopedConsScope :: core
  }
  deriving (Eq, Functor, Foldable, Show, Traversable)
makeLenses ''ScopedCons

data ScopedList core = ScopedList
  { _scopedListElements :: [core]
  , _scopedListScope    :: core
  }
  deriving (Eq, Functor, Foldable, Show, Traversable)
makeLenses ''ScopedList

data CoreF core
  = CoreVar Var
  | CoreLam Ident Var core
  | CoreApp core core
  | CorePure core                       -- :: a -> Macro a
  | CoreBind core core                  -- :: Macro a -> (a -> Macro b) -> Macro b
  | CoreSyntaxError (SyntaxError core)  -- :: Macro a
  | CoreSendSignal core                 -- :: Signal -> Macro ()
  | CoreWaitSignal core                 -- :: Signal -> Macro ()
  | CoreFreeIdentEq core core           -- :: Syntax -> Syntax -> Macro Bool
  | CoreBoundIdentEq core core          -- :: Syntax -> Syntax -> Bool
  | CoreLog core
  | CoreSyntax Syntax
  | CoreCase core [(Pattern, core)]
  | CoreIdentifier Ident
  | CoreSignal Signal
  | CoreBool Bool
  | CoreIf core core core
  | CoreIdent (ScopedIdent core)
  | CoreEmpty (ScopedEmpty core)
  | CoreCons (ScopedCons core)
  | CoreList (ScopedList core)
  deriving (Eq, Functor, Foldable, Show, Traversable)
makePrisms ''CoreF

instance Phased core => Phased (CoreF core) where
  shift i (CoreIdentifier ident) = CoreIdentifier (shift i ident)
  shift i (CoreSyntax stx) = CoreSyntax (shift i stx)
  shift i other = fmap (shift i) other

newtype Core = Core
  { unCore :: CoreF Core }
  deriving (Eq, Show)
makePrisms ''Core

instance Phased Core where
  shift i (Core c) = Core (shift i c)

instance AlphaEq a => AlphaEq (SyntaxError a) where
  alphaCheck (SyntaxError locations1 message1)
             (SyntaxError locations2 message2) = do
    alphaCheck locations1 locations2
    alphaCheck message1   message2

instance AlphaEq core => AlphaEq (CoreF core) where
  alphaCheck (CoreVar var1)
             (CoreVar var2) = do
    alphaCheck var1 var2
  alphaCheck (CoreLam _ var1 body1)
             (CoreLam _ var2 body2) = do
    alphaCheck var1   var2
    alphaCheck body1  body2
  alphaCheck (CoreApp fun1 arg1)
             (CoreApp fun2 arg2) = do
    alphaCheck fun1 fun2
    alphaCheck arg1 arg2
  alphaCheck (CorePure x1)
             (CorePure x2) = do
    alphaCheck x1 x2
  alphaCheck (CoreBind hd1 tl1)
             (CoreBind hd2 tl2) = do
    alphaCheck hd1 hd2
    alphaCheck tl1 tl2
  alphaCheck (CoreSyntaxError syntaxError1)
             (CoreSyntaxError syntaxError2) = do
    alphaCheck syntaxError1 syntaxError2
    alphaCheck syntaxError1 syntaxError2
  alphaCheck (CoreSendSignal signal1)
             (CoreSendSignal signal2) = do
    alphaCheck signal1 signal2
  alphaCheck (CoreWaitSignal signal1)
             (CoreWaitSignal signal2) = do
    alphaCheck signal1 signal2
  alphaCheck (CoreFreeIdentEq e1 g1)
             (CoreFreeIdentEq e2 g2) = do
    alphaCheck e1 e2
    alphaCheck g1 g2
  alphaCheck (CoreBoundIdentEq e1 g1)
             (CoreBoundIdentEq e2 g2) = do
    alphaCheck e1 e2
    alphaCheck g1 g2
  alphaCheck (CoreSyntax syntax1)
             (CoreSyntax syntax2) = do
    alphaCheck syntax1 syntax2
  alphaCheck (CoreCase scrutinee1 cases1)
             (CoreCase scrutinee2 cases2) = do
    alphaCheck scrutinee1 scrutinee2
    alphaCheck cases1 cases2
  alphaCheck (CoreIdentifier stx1)
             (CoreIdentifier stx2) = do
    alphaCheck stx1 stx2
  alphaCheck (CoreSignal s1)
             (CoreSignal s2) =
    guard $ s1 == s2
  alphaCheck (CoreBool b1)
             (CoreBool b2) =
    guard $ b1 == b2
  alphaCheck (CoreIf b1 t1 f1)
             (CoreIf b2 t2 f2) = do
    alphaCheck b1 b2
    alphaCheck t1 t2
    alphaCheck f1 f2
  alphaCheck (CoreIdent scopedIdent1)
             (CoreIdent scopedIdent2) = do
    alphaCheck scopedIdent1 scopedIdent2
  alphaCheck (CoreEmpty scopedEmpty1)
             (CoreEmpty scopedEmpty2) = do
    alphaCheck scopedEmpty1 scopedEmpty2
  alphaCheck (CoreCons scopedCons1)
             (CoreCons scopedCons2) = do
    alphaCheck scopedCons1 scopedCons2
  alphaCheck (CoreList scopedVec1)
             (CoreList scopedVec2) = do
    alphaCheck scopedVec1 scopedVec2
  alphaCheck _ _ = notAlphaEquivalent

instance AlphaEq Core where
  alphaCheck (Core x1)
             (Core x2) = do
    alphaCheck x1 x2

instance AlphaEq Pattern where
  alphaCheck (PatternIdentifier _ x1)
             (PatternIdentifier _ x2) = do
    alphaCheck x1 x2
  alphaCheck PatternEmpty
             PatternEmpty = do
    pure ()
  alphaCheck (PatternCons _ x1 _ xs1)
             (PatternCons _ x2 _ xs2) = do
    alphaCheck x1   x2
    alphaCheck xs1  xs2
  alphaCheck (PatternList xs1)
             (PatternList xs2) = do
    alphaCheck (map snd xs1) (map snd xs2)
  alphaCheck _ _ = notAlphaEquivalent

instance AlphaEq core => AlphaEq (ScopedIdent core) where
  alphaCheck (ScopedIdent ident1 scope1)
             (ScopedIdent ident2 scope2) = do
    alphaCheck ident1 ident2
    alphaCheck scope1 scope2

instance AlphaEq core => AlphaEq (ScopedEmpty core) where
  alphaCheck (ScopedEmpty scope1)
             (ScopedEmpty scope2) = do
    alphaCheck scope1 scope2

instance AlphaEq core => AlphaEq (ScopedCons core) where
  alphaCheck (ScopedCons hd1 tl1 scope1)
             (ScopedCons hd2 tl2 scope2) = do
    alphaCheck hd1    hd2
    alphaCheck tl1    tl2
    alphaCheck scope1 scope2

instance AlphaEq core => AlphaEq (ScopedList core) where
  alphaCheck (ScopedList elements1 scope1)
             (ScopedList elements2 scope2) = do
    alphaCheck elements1 elements2
    alphaCheck scope1    scope2


instance ShortShow a => ShortShow (SyntaxError a) where
  shortShow (SyntaxError locations message)
    = "(SyntaxError "
   ++ shortShow locations
   ++ " "
   ++ shortShow message
   ++ ")"

instance ShortShow Var where
  shortShow (Var x) = shortShow x

instance ShortShow core => ShortShow (CoreF core) where
  shortShow (CoreVar var)
    = "(Var "
   ++ shortShow var
   ++ ")"
  shortShow (CoreLam _ x body)
    = "(Lam "
   ++ shortShow x
   ++ " "
   ++ shortShow body
   ++ ")"
  shortShow (CoreApp fun arg)
    = "(App "
   ++ shortShow fun
   ++ " "
   ++ shortShow arg
   ++ ")"
  shortShow (CorePure x)
    = "(Pure "
   ++ shortShow x
   ++ ")"
  shortShow (CoreBind hd tl)
    = "(Bind "
   ++ shortShow hd
   ++ " "
   ++ shortShow tl
   ++ ")"
  shortShow (CoreSyntaxError syntaxError)
    = "(SyntaxError "
   ++ shortShow syntaxError
   ++ ")"
  shortShow (CoreSendSignal signal)
    = "(SendSignal "
   ++ shortShow signal
   ++ ")"
  shortShow (CoreWaitSignal signal)
    = "(WaitSignal "
   ++ shortShow signal
   ++ ")"
  shortShow (CoreFreeIdentEq e1 e2)
    = "(CoreFreeIdentEq "
    ++ " " ++ shortShow e1
    ++ " " ++ shortShow e2 ++ ")"
  shortShow (CoreBoundIdentEq e1 e2)
    = "(CoreBoundIdentEq "
    ++ " " ++ shortShow e1
    ++ " " ++ shortShow e2 ++ ")"
  shortShow (CoreLog msg)
    = "(CoreLog " ++ shortShow msg ++ ")"
  shortShow (CoreSyntax syntax)
    = "(Syntax "
   ++ shortShow syntax
   ++ ")"
  shortShow (CoreCase scrutinee cases)
    = "(Case "
   ++ shortShow scrutinee
   ++ " "
   ++ shortShow cases
   ++ ")"
  shortShow (CoreIdentifier stx)
    = "(Identifier "
   ++ shortShow stx
   ++ ")"
  shortShow (CoreSignal signal)
    = shortShow signal
  shortShow (CoreBool b)
    = if b then "#true" else "#false"
  shortShow (CoreIf b t f)
    = "(if " ++ shortShow b ++ " " ++
      shortShow t ++ " " ++
      shortShow f ++ ")"
  shortShow (CoreIdent scopedIdent)
    = "(Ident "
   ++ shortShow scopedIdent
   ++ ")"
  shortShow (CoreEmpty scopedEmpty)
    = "(Empty "
   ++ shortShow scopedEmpty
   ++ ")"
  shortShow (CoreCons scopedCons)
    = "(Cons "
   ++ shortShow scopedCons
   ++ ")"
  shortShow (CoreList scopedVec)
    = "(List "
   ++ shortShow scopedVec
   ++ ")"

instance ShortShow Core where
  shortShow (Core x) = shortShow x

instance ShortShow Pattern where
  shortShow (PatternIdentifier _ x) = shortShow x
  shortShow PatternEmpty = "Empty"
  shortShow (PatternCons _ x _ xs)
    = "(Cons "
   ++ shortShow x
   ++ " "
   ++ shortShow xs
   ++ ")"
  shortShow (PatternList xs)
    = "(List "
   ++ shortShow (map snd xs)
   ++ ")"
  shortShow PatternAny = "_"

instance ShortShow core => ShortShow (ScopedIdent core) where
  shortShow (ScopedIdent ident scope)
    = "(ScopedIdent "
   ++ shortShow ident
   ++ " "
   ++ shortShow scope
   ++ ")"

instance ShortShow core => ShortShow (ScopedEmpty core) where
  shortShow (ScopedEmpty scope)
    = "(ScopedEmpty "
   ++ shortShow scope
   ++ ")"

instance ShortShow core => ShortShow (ScopedCons core) where
  shortShow (ScopedCons hd tl scope)
    = "(ScopedCons "
   ++ shortShow hd
   ++ " "
   ++ shortShow tl
   ++ " "
   ++ shortShow scope
   ++ ")"

instance ShortShow core => ShortShow (ScopedList core) where
  shortShow (ScopedList elements scope)
    = "(ScopedList "
   ++ shortShow elements
   ++ " "
   ++ shortShow scope
   ++ ")"
