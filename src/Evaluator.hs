{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
module Evaluator where

import Control.Lens hiding (List, elements)
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.RWS.Strict
import Data.Foldable (for_)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Text (Text)
import qualified Data.Text as T

import Core
import Env
import Module
import Phase
import Signals
import Syntax
import Value

-- TODO: more precise representation
type Type = Text

data TypeError = TypeError
  { _typeErrorExpected :: Type
  , _typeErrorActual   :: Type
  }
  deriving (Eq, Show)
makeLenses ''TypeError

data EvalError
  = EvalErrorUnbound Var
  | EvalErrorType TypeError
  | EvalErrorCase Value
  deriving (Eq, Show)
makePrisms ''EvalError

evalErrorText :: EvalError -> Text
evalErrorText (EvalErrorUnbound x) = "Unbound: " <> T.pack (show x)
evalErrorText (EvalErrorType (TypeError expected got)) =
  "Wrong type. Expected a " <> expected <> " but got a " <> got
evalErrorText (EvalErrorCase val) =
  "Didn't match any pattern: " <> valueText val

newtype Eval a = Eval
   { runEval :: ReaderT VEnv (ExceptT EvalError IO) a }
   deriving (Functor, Applicative, Monad, MonadReader VEnv, MonadError EvalError)

withEnv :: VEnv -> Eval a -> Eval a
withEnv = local . const

withExtendedEnv :: Ident -> Var -> Value -> Eval a -> Eval a
withExtendedEnv n x v act = local (Env.insert x n v) act

withManyExtendedEnv :: [(Ident, Var, Value)] -> Eval a -> Eval a
withManyExtendedEnv exts act = local (inserter exts) act
  where
    inserter [] = id
    inserter ((n, x, v) : rest) = Env.insert x n v . inserter rest

-- | 'resultValue' is the result of evaluating the 'resultExpr' in 'resultCtx'
data EvalResult =
  EvalResult { resultEnv :: VEnv
             , resultExpr :: Core
             , resultValue :: Value
             }
  deriving (Eq, Show)


-- | Evaluate a module at some phase. Return the resulting
-- environments and transformer environments for each phase and the
-- closure and value for each example in the module.
evalMod ::
  Map Phase VEnv {- ^ The environments for each phase -} ->
  Map Phase TEnv {- ^ The transformer environments for each phase -} ->
  Phase          {- ^ The current phase -} ->
  CompleteModule {- ^ The source code of a fully-expanded module -} ->
  Eval ( Map Phase VEnv
       , Map Phase TEnv
       , [EvalResult]
       )
evalMod startingEnvs startingTransformers basePhase m =
  case m of
    KernelModule _p ->
       -- Builtins go here, suitably shifted. There are no built-in
       -- values yet, only built-in syntax, but this may change.
      return (Map.empty, Map.empty, [])
    Expanded em _ ->
      fmap (\((x, y), z) -> (x, y, z)) $
        execRWST (traverse evalDecl (view moduleBody em)) basePhase
          (startingEnvs, startingTransformers)

  where
    currentEnv ::
      Monoid w =>
      RWST Phase w (Map Phase VEnv, other) Eval VEnv
    currentEnv = do
      p <- ask
      envs <- fst <$> get
      case Map.lookup p envs of
        Nothing -> return Env.empty
        Just env -> return env

    extendCurrentEnv ::
      Monoid w =>
      Var -> Ident -> Value ->
      RWST Phase w (Map Phase VEnv, other) Eval ()
    extendCurrentEnv n x v = do
      p <- ask
      modify $ over _1 $ \envs ->
        case Map.lookup p envs of
          Just env -> Map.insert p (Env.insert n x v env) envs
          Nothing -> Map.insert p (Env.singleton n x v) envs

    extendCurrentTransformerEnv ::
      Monoid w =>
      MacroVar -> Ident -> Value ->
      RWST Phase w (other, Map Phase TEnv) Eval ()
    extendCurrentTransformerEnv n x v = do
      p <- ask
      modify $ over _2 $ \envs ->
        case Map.lookup p envs of
          Just env -> Map.insert p (Env.insert n x v env) envs
          Nothing -> Map.insert p (Env.singleton n x v) envs


    evalDecl ::
      CompleteDecl ->
      RWST Phase
           [EvalResult]
           (Map Phase VEnv, Map Phase TEnv)
           Eval
           ()
    evalDecl (CompleteDecl d) = evalDecl' d
      where
      evalDecl' (Define x n e) = do
        env <- currentEnv
        v <- lift $ withEnv env (eval e)
        extendCurrentEnv n x v
      evalDecl' (Example expr) = do
        env <- currentEnv
        value <- lift $ withEnv env (eval expr)
        tell $ [EvalResult { resultEnv = env
                           , resultExpr = expr
                           , resultValue = value
                           }]
      evalDecl' (DefineMacros macros) = do
        env <- local prior currentEnv
        for_ macros $ \(x, n, e) -> do
          v <- lift $ withEnv env (eval e)
          extendCurrentTransformerEnv n x v
      evalDecl' (Meta decl) = local prior (evalDecl decl)
      evalDecl' (Import _spec) = pure ()
      evalDecl' (Export _x) = pure ()


apply :: Closure -> Value -> Eval Value
apply (Closure {..}) value = do
  let env = Env.insert _closureVar
                       _closureIdent
                       value
                       _closureEnv
  withEnv env $ do
    eval _closureBody

eval :: Core -> Eval Value
eval (Core (CoreVar var)) = do
  env <- ask
  case lookupVal var env of
    Just value -> pure value
    _ -> throwError $ EvalErrorUnbound var
eval (Core (CoreLam ident var body)) = do
  env <- ask
  pure $ ValueClosure $ Closure
    { _closureEnv   = env
    , _closureIdent = ident
    , _closureVar   = var
    , _closureBody  = body
    }
eval (Core (CoreApp fun arg)) = do
  closure <- evalAsClosure fun
  value <- eval arg
  apply closure value
eval (Core (CorePure arg)) = do
  value <- eval arg
  pure $ ValueMacroAction
       $ MacroActionPure value
eval (Core (CoreBind hd tl)) = do
  macroAction <- evalAsMacroAction hd
  closure <- evalAsClosure tl
  pure $ ValueMacroAction
       $ MacroActionBind macroAction closure
eval (Core (CoreSyntaxError syntaxErrorExpr)) = do
  syntaxErrorValue <- traverse evalAsSyntax syntaxErrorExpr
  pure $ ValueMacroAction
       $ MacroActionSyntaxError syntaxErrorValue
eval (Core (CoreSendSignal signalExpr)) = do
  theSignal <- evalAsSignal signalExpr
  pure $ ValueMacroAction
       $ MacroActionSendSignal theSignal
eval (Core (CoreWaitSignal signalExpr)) = do
  theSignal <- evalAsSignal signalExpr
  pure $ ValueMacroAction
       $ MacroActionWaitSignal theSignal
eval (Core (CoreIdentEq how e1 e2)) =
  ValueMacroAction <$> (MacroActionIdentEq how <$> eval e1 <*> eval e2)
eval (Core (CoreSignal signal)) =
  pure $ ValueSignal signal
eval (Core (CoreSyntax syntax)) = do
  pure $ ValueSyntax syntax
eval (Core (CoreCase scrutinee cases)) = do
  v <- eval scrutinee
  doCase v cases
eval (Core (CoreIdentifier (Stx scopeSet srcLoc name))) = do
  pure $ ValueSyntax
       $ Syntax
       $ Stx scopeSet srcLoc
       $ Id name
eval (Core (CoreBool b)) = pure $ ValueBool b
eval (Core (CoreIf b t f)) =
  eval b >>=
  \case
    ValueBool True -> eval t
    ValueBool False -> eval f
    other ->
      throwError $ EvalErrorType $ TypeError
        { _typeErrorExpected = "boolean"
        , _typeErrorActual   = describeVal other
        }
eval (Core (CoreIdent (ScopedIdent ident scope))) = do
  identSyntax <- evalAsSyntax ident
  case identSyntax of
    Syntax (Stx _ _ expr) ->
      case expr of
        Sig _ ->
          throwError $ EvalErrorType $ TypeError
            { _typeErrorExpected = "id"
            , _typeErrorActual   = "signal"
            }
        String _ ->
          throwError $ EvalErrorType $ TypeError
            { _typeErrorExpected = "id"
            , _typeErrorActual   = "string"
            }
        Bool _ ->
          throwError $ EvalErrorType $ TypeError
            { _typeErrorExpected = "id"
            , _typeErrorActual   = "boolean"
            }
        List _ ->
          throwError $ EvalErrorType $ TypeError
            { _typeErrorExpected = "id"
            , _typeErrorActual   = "list"
            }
        Vec _ ->
          throwError $ EvalErrorType $ TypeError
            { _typeErrorExpected = "id"
            , _typeErrorActual   = "vec"
            }
        Id name -> withScopeOf scope $ Id name
eval (Core (CoreEmpty (ScopedEmpty scope))) = withScopeOf scope (List [])
eval (Core (CoreCons (ScopedCons hd tl scope))) = do
  hdSyntax <- evalAsSyntax hd
  tlSyntax <- evalAsSyntax tl
  case tlSyntax of
    Syntax (Stx _ _ expr) ->
      case expr of
        List vs -> withScopeOf scope $ List $ hdSyntax : vs
        Vec _ ->
          throwError $ EvalErrorType $ TypeError
            { _typeErrorExpected = "list"
            , _typeErrorActual   = "vec"
            }
        String _ ->
          throwError $ EvalErrorType $ TypeError
            { _typeErrorExpected = "list"
            , _typeErrorActual   = "string"
            }
        Bool _ ->
          throwError $ EvalErrorType $ TypeError
            { _typeErrorExpected = "list"
            , _typeErrorActual   = "boolean"
            }
        Id _ ->
          throwError $ EvalErrorType $ TypeError
            { _typeErrorExpected = "list"
            , _typeErrorActual   = "id"
            }
        Sig _ ->
          throwError $ EvalErrorType $ TypeError
            { _typeErrorExpected = "list"
            , _typeErrorActual   = "signal"
            }
eval (Core (CoreVec (ScopedVec elements scope))) = do
  vec <- Vec <$> traverse evalAsSyntax elements
  withScopeOf scope vec

evalErrorType :: Text -> Value -> Eval a
evalErrorType expected got =
  throwError $ EvalErrorType $ TypeError
    { _typeErrorExpected = expected
    , _typeErrorActual   = describeVal got
    }

evalAsClosure :: Core -> Eval Closure
evalAsClosure core = do
  value <- eval core
  case value of
    ValueClosure closure -> do
      pure closure
    other -> evalErrorType "function" other

evalAsSignal :: Core -> Eval Signal
evalAsSignal core = do
  value <- eval core
  case value of
    ValueSignal s -> pure s
    other -> evalErrorType "signal" other

evalAsSyntax :: Core -> Eval Syntax
evalAsSyntax core = do
  value <- eval core
  case value of
    ValueSyntax syntax -> pure syntax
    other -> evalErrorType "syntax" other

evalAsMacroAction :: Core -> Eval MacroAction
evalAsMacroAction core = do
  value <- eval core
  case value of
    ValueMacroAction macroAction -> pure macroAction
    other -> evalErrorType "macro action" other

withScopeOf :: Core -> ExprF Syntax -> Eval Value
withScopeOf scope expr = do
  scopeSyntax <- evalAsSyntax scope
  case scopeSyntax of
    Syntax (Stx scopeSet loc _) ->
      pure $ ValueSyntax $ Syntax $ Stx scopeSet loc expr

doCase :: Value -> [(Pattern, Core)] -> Eval Value
doCase v0 []               = throwError (EvalErrorCase v0)
doCase v0 ((p, rhs0) : ps) = match (doCase v0 ps) p rhs0 v0
  where
    match next (PatternIdentifier n x) rhs =
      \case
        v@(ValueSyntax (Syntax (Stx _ _ (Id _)))) ->
          withExtendedEnv n x v (eval rhs)
        _ -> next
    match next PatternEmpty rhs =
      \case
        (ValueSyntax (Syntax (Stx _ _ (List [])))) ->
          eval rhs
        _ -> next
    match next (PatternCons nx x nxs xs) rhs =
      \case
        (ValueSyntax (Syntax (Stx scs loc (List (v:vs))))) ->
          withExtendedEnv nx x (ValueSyntax v) $
          withExtendedEnv nxs xs (ValueSyntax (Syntax (Stx scs loc (List vs)))) $
          eval rhs
        _ -> next
    match next (PatternVec xs) rhs =
      \case
        (ValueSyntax (Syntax (Stx _ _ (Vec vs))))
          | length vs == length xs ->
            withManyExtendedEnv [(n, x, (ValueSyntax v))
                                | (n,x) <- xs
                                | v <- vs] $
            eval rhs
        _ -> next
