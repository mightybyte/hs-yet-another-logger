-- Copyright (c) 2014-2015 PivotCloud, Inc.
--
-- System.Logger.Types
--
-- Please feel free to contact us at licensing@pivotmail.com with any
-- contributions, additions, or other feedback; we would love to hear from
-- you.
--
-- Licensed under the Apache License, Version 2.0 (the "License"); you may
-- not use this file except in compliance with the License. You may obtain a
-- copy of the License at http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
-- WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
-- License for the specific language governing permissions and limitations
-- under the License.

-- |
-- Module: System.Logger.Types
-- Description: Basic Types of Yet Another Logger
-- Copyright: Copyright (c) 2014-2015 PivotCloud, Inc.
-- License: Apache License, Version 2.0
-- Maintainer: Lars Kuhtz <lkuhtz@pivotmail.com>
-- Stability: experimental
--

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UnicodeSyntax #-}

module System.Logger.Types
(
-- * LogLevel
  LogLevel(..)
, logLevelText
, readLogLevel
, pLogLevel

-- * LogPolicy
, LogPolicy(..)
, logPolicyText
, readLogPolicy
, pLogPolicy

-- * LogLabel
, LogLabel
, LogScope

-- * Logger Backend
, LogMessage(..)
, logMsg
, logMsgLevel
, logMsgScope
, LoggerBackend

-- * Logger Frontend
, LogFunction
, LogFunctionIO

-- * LoggerCtx
, LoggerCtx(..)
, LoggerCtxT
, runLoggerCtxT

-- * MonadLog
, MonadLog(..)

) where

import Configuration.Utils hiding (Lens', Error)

import Control.DeepSeq
import Control.Lens hiding ((.=))
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.Trans.Control
import Control.Monad.Trans.Either
import Control.Monad.Trans.State
import Control.Monad.Trans.Trace
import Control.Monad.Trans.Writer
import Control.Monad.Unicode

import qualified Data.CaseInsensitive as CI
import Data.Monoid
import Data.Monoid.Unicode
import Data.String
import qualified Data.Text as T
import Data.Text.Lens
import Data.Typeable

import GHC.Generics

import qualified Options.Applicative as O

import Prelude.Unicode

-- -------------------------------------------------------------------------- --
-- Log-Level

data LogLevel
    = Quiet
    | Error
    | Warn
    | Info
    | Debug
    deriving (Show, Read, Eq, Ord, Enum, Bounded, Typeable, Generic)

instance NFData LogLevel

readLogLevel
    ∷ (MonadError e m, Eq a, Show a, CI.FoldCase a, IsString a, IsString e, Monoid e)
    ⇒ a
    → m LogLevel
readLogLevel x = case CI.mk x of
    "quiet" → return Quiet
    "error" → return Error
    "warn" → return Warn
    "info" → return Info
    "debug" → return Debug
    e → throwError $ "unexpected log level value: "
        ⊕ fromString (show e)
        ⊕ ", expected \"quiet\", \"error\", \"warn\", \"info\", or \"debug\""

logLevelText
    ∷ IsString a
    ⇒ LogLevel
    → a
logLevelText Quiet = "quiet"
logLevelText Error = "error"
logLevelText Warn = "warn"
logLevelText Info = "info"
logLevelText Debug = "debug"

instance ToJSON LogLevel where
    toJSON = String ∘ logLevelText

instance FromJSON LogLevel where
    parseJSON = withText "LogLevel" $ either fail return ∘ readLogLevel

pLogLevel ∷ O.Parser LogLevel
pLogLevel = option (eitherReader readLogLevel)
    × long "loglevel"
    ⊕ metavar "quiet|error|warn|info|debug"
    ⊕ help "threshold for log messages"

-- -------------------------------------------------------------------------- --
-- Log Policy

-- | Policy that determines how the case of a congested logging
-- pipeline is addressed.
--
data LogPolicy
    = LogPolicyDiscard
    | LogPolicyRaise
    | LogPolicyBlock
    deriving (Show, Read, Eq, Ord, Bounded, Enum, Typeable, Generic)

logPolicyText ∷ IsString s ⇒ LogPolicy → s
logPolicyText LogPolicyDiscard = "discard"
logPolicyText LogPolicyRaise = "raise"
logPolicyText LogPolicyBlock = "block"

readLogPolicy
    ∷ (MonadError e m, Eq a, Show a, CI.FoldCase a, IsText a, IsString e, Monoid e)
    ⇒ a
    → m LogPolicy
readLogPolicy x = case CI.mk tx of
    "discard" → return LogPolicyDiscard
    "raise" → return LogPolicyRaise
    "block" → return LogPolicyBlock
    e → throwError
        $ "invalid log policy value " ⊕ fromString (show e) ⊕ ";"
        ⊕ " the log policy value must be one of \"discard\", \"raise\", or \"block\""
  where
    tx = packed # x

instance ToJSON LogPolicy where
    toJSON = toJSON ∘ (logPolicyText ∷ LogPolicy → T.Text)

instance FromJSON LogPolicy where
    parseJSON = withText "LogPolicy" $ either fail return ∘ readLogPolicy

pLogPolicy ∷ O.Parser LogPolicy
pLogPolicy = option (eitherReader readLogPolicy)
    × long "log-policy"
    ⊕ metavar "block|raise|discard"
    ⊕ help "how to deal with a congested logging pipeline"

-- -------------------------------------------------------------------------- --
-- Log-Label

type LogLabel = (T.Text, T.Text)
type LogScope = [LogLabel]

-- -------------------------------------------------------------------------- --
-- Backend

-- | The Internal log message type.
--
-- The type parameter @a@ is expected to provide intances
-- of 'Show', 'Typeable', and 'NFData'.
--
-- If we need to support different backends, we may consider
-- including the backend here...
--
data LogMessage a = LogMessage
    { _logMsg ∷ !a
    , _logMsgLevel ∷ !LogLevel
    , _logMsgScope ∷ !LogScope
        -- ^ efficiency of this depends on whether this is shared
        -- between log messsages. Usually this should be just a pointer to
        -- a shared list.
    }
    deriving (Show, Read, Eq, Ord, Typeable, Generic)

logMsg ∷ Lens' (LogMessage a) a
logMsg = lens _logMsg $ \a b → a { _logMsg = b }

logMsgLevel ∷ Lens' (LogMessage a) LogLevel
logMsgLevel = lens _logMsgLevel $ \a b → a { _logMsgLevel = b }

logMsgScope ∷ Lens' (LogMessage a) LogScope
logMsgScope = lens _logMsgScope $ \a b → a { _logMsgScope = b }

instance NFData a ⇒ NFData (LogMessage a)

-- | This is given to logger when it is created. It formats and delivers
-- individual log messages synchronously.
--
-- The type parameter @a@ is expected to provide instances for 'Show'
-- 'Typeable', and 'NFData'.
--
-- The 'Left' values of the argument allows the generation of log messages
-- that are independent of the parameter @a@. The motivation for this is
-- reporting issues in Logging system itself, like a full logger queue
-- or providing statistics about the fill level of the queue. There may
-- be other uses of this, too.
--
-- TODO there may be scenarios where chunked processing is beneficial.
-- While this can be done in a closure of this function a more direct
-- support might be desirable.
--
type LoggerBackend a = Either (LogMessage T.Text) (LogMessage a) → IO ()

-- -------------------------------------------------------------------------- --
-- Frontend

-- | This function is provided by the logger.
--
type LogFunctionIO a = LogLevel → a → IO ()
type LogFunction a m = LogLevel → a → m ()

-- -------------------------------------------------------------------------- --
-- MonadLog

class Monad m ⇒ MonadLog a m | m → a where
    logg ∷ LogFunction a m
    withLevel ∷ LogLevel → m α → m α
    withLabel ∷ LogLabel → m α → m α
    withPolicy ∷ LogPolicy → m α → m α

-- Not sure if this instance is a good idea
instance (Show a, Typeable a, NFData a, MonadIO m, LoggerCtx ctx a, MonadReader ctx m) ⇒ MonadLog a m where
    logg l m = ask ≫= \ctx → liftIO (loggerFunIO ctx l m)
    withLevel level = local $ setLoggerLevel .~ level
    withLabel label = local $ setLoggerScope %~ (:) label
    withPolicy policy = local $ setLoggerPolicy .~ policy

    {-# INLINE logg #-}
    {-# INLINE withLevel #-}
    {-# INLINE withLabel #-}
    {-# INLINE withPolicy #-}

-- Not sure if this instance is a good idea
instance MonadLog a m ⇒ MonadLog a (ReaderT σ m) where
    logg l = lift ∘ logg l
    withLevel level inner = liftWith (\run → withLevel level (run inner)) ≫= restoreT ∘ return
    withLabel label inner = liftWith (\run → withLabel label (run inner)) ≫= restoreT ∘ return
    withPolicy policy inner = liftWith (\run → withPolicy policy (run inner)) ≫= restoreT ∘ return

    {-# INLINE logg #-}
    {-# INLINE withLevel #-}
    {-# INLINE withLabel #-}
    {-# INLINE withPolicy #-}

instance (Monoid σ, MonadLog a m) ⇒ MonadLog a (WriterT σ m) where
    logg l = lift ∘ logg l
    withLevel level inner = liftWith (\run → withLevel level (run inner)) ≫= restoreT ∘ return
    withLabel label inner = liftWith (\run → withLabel label (run inner)) ≫= restoreT ∘ return
    withPolicy policy inner = liftWith (\run → withPolicy policy (run inner)) ≫= restoreT ∘ return

    {-# INLINE logg #-}
    {-# INLINE withLevel #-}
    {-# INLINE withLabel #-}
    {-# INLINE withPolicy #-}

instance (MonadLog a m) ⇒ MonadLog a (ExceptT ε m) where
    logg l = lift ∘ logg l
    withLevel level inner = liftWith (\run → withLevel level (run inner)) ≫= restoreT ∘ return
    withLabel label inner = liftWith (\run → withLabel label (run inner)) ≫= restoreT ∘ return
    withPolicy policy inner = liftWith (\run → withPolicy policy (run inner)) ≫= restoreT ∘ return

    {-# INLINE logg #-}
    {-# INLINE withLevel #-}
    {-# INLINE withLabel #-}
    {-# INLINE withPolicy #-}

instance (MonadLog a m) ⇒ MonadLog a (StateT σ m) where
    logg l = lift ∘ logg l
    withLevel level inner = liftWith (\run → withLevel level (run inner)) ≫= restoreT ∘ return
    withLabel label inner = liftWith (\run → withLabel label (run inner)) ≫= restoreT ∘ return
    withPolicy policy inner = liftWith (\run → withPolicy policy (run inner)) ≫= restoreT ∘ return

    {-# INLINE logg #-}
    {-# INLINE withLevel #-}
    {-# INLINE withLabel #-}
    {-# INLINE withPolicy #-}

instance (MonadLog a m) ⇒ MonadLog a (TraceT t e m) where
    logg l = lift ∘ logg l
    withLevel level inner = liftWith (\run → withLevel level (run inner)) ≫= restoreT ∘ return
    withLabel label inner = liftWith (\run → withLabel label (run inner)) ≫= restoreT ∘ return
    withPolicy policy inner = liftWith (\run → withPolicy policy (run inner)) ≫= restoreT ∘ return

    {-# INLINE logg #-}
    {-# INLINE withLevel #-}
    {-# INLINE withLabel #-}
    {-# INLINE withPolicy #-}

instance (MonadLog a m) ⇒ MonadLog a (EitherT σ m) where
    logg l = lift ∘ logg l
    withLevel level inner = liftWith (\run → withLevel level (run inner)) ≫= restoreT ∘ return
    withLabel label inner = liftWith (\run → withLabel label (run inner)) ≫= restoreT ∘ return
    withPolicy policy inner = liftWith (\run → withPolicy policy (run inner)) ≫= restoreT ∘ return

    {-# INLINE logg #-}
    {-# INLINE withLevel #-}
    {-# INLINE withLabel #-}
    {-# INLINE withPolicy #-}

{-
-- Uses @OverlappingInstances@ to lift MonadLog in all transformers with an
-- instance for 'MonadTransControl'.
--
-- It would be really cool if this would work
--
instance (MonadLog a m, MonadTransControl t, Monad n, n ~ (t m)) ⇒ MonadLog a n where
    logg l = lift ∘ logg l
    withLevel level inner = liftWith (\run → withLevel level (run inner)) ≫= restoreT ∘ return
    withLabel label inner = liftWith (\run → withLabel label (run inner)) ≫= restoreT ∘ return
    withPolicy policy inner = liftWith (\run → withPolicy policy (run inner)) ≫= restoreT ∘ return

    {-# INLINE logg #-}
    {-# INLINE withLevel #-}
    {-# INLINE withLabel #-}
    {-# INLINE withPolicy #-}
-}

-- -------------------------------------------------------------------------- --
-- Logger Context

-- | Abstraction of a logger context that can be used without dependening on
-- a specific monadic context.
--
-- The 'loggerFunIO' incorporates a 'LoggerBackend'. An instance of a 'LoggerCtx'
-- is free to use a hard coded 'LoggerBackend' or to be usable with different
-- 'LoggerBackend' functions. The latter is recommended but not required.
--
-- You don't have to provide an instance of this for your logger. Instead you
-- may just provide an instance of 'MonadLog' directly.
--
-- If this doesn't fit your needs you may use a newtype wrapper and define
-- your own instances.
--
class LoggerCtx ctx msg | ctx → msg where
    loggerFunIO
        ∷ (Show msg, Typeable msg, NFData msg)
        ⇒ ctx
        → LogFunctionIO msg

    setLoggerLevel ∷ Setter' ctx LogLevel
    setLoggerScope ∷ Setter' ctx LogScope
    setLoggerPolicy ∷ Setter' ctx LogPolicy

    withLoggerLevel ∷ LogLevel → ctx → (ctx → α) → α
    withLoggerLevel level ctx f = f $ ctx & setLoggerLevel .~ level
    {-# INLINE withLoggerLevel #-}

    withLoggerLabel ∷ LogLabel → ctx → (ctx → α) → α
    withLoggerLabel label ctx f = f $ ctx & setLoggerScope %~ (:) label
    {-# INLINE withLoggerLabel #-}

    withLoggerPolicy ∷ LogPolicy → ctx → (ctx → α) → α
    withLoggerPolicy policy ctx f = f $ ctx & setLoggerPolicy .~ policy
    {-# INLINE withLoggerPolicy #-}

newtype LoggerCtxT ctx m α = LoggerCtxT (ReaderT ctx m α)
    deriving (Functor, Applicative, Monad, MonadIO, MonadTrans, MonadReader ctx)

runLoggerCtxT
    ∷ LoggerCtxT ctx m α
    → ctx
    → m α
runLoggerCtxT (LoggerCtxT a) = runReaderT a

instance (Show a, Typeable a, NFData a, MonadIO m, LoggerCtx ctx a) ⇒ MonadLog a (LoggerCtxT ctx m) where
    logg l m = ask ≫= \ctx → liftIO (loggerFunIO ctx l m)
    withLevel level = local $ setLoggerLevel .~ level
    withLabel label = local $ setLoggerScope %~ (:) label
    withPolicy policy = local $ setLoggerPolicy .~ policy

    {-# INLINE logg #-}
    {-# INLINE withLevel #-}
    {-# INLINE withLabel #-}
    {-# INLINE withPolicy #-}
