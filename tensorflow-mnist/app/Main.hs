-- Copyright 2016 TensorFlow authors.
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedLists #-}

import Control.Monad (zipWithM, when, forM, forM_)
import Control.Monad.IO.Class (liftIO)
import Data.Int (Int32, Int64)
import Data.List (genericLength)
import qualified Data.Text.IO as T
import qualified Data.Vector as V

import qualified TensorFlow.Build as TF
import qualified TensorFlow.ControlFlow as TF
import qualified TensorFlow.Gradient as TF
import qualified TensorFlow.Nodes as TF
import qualified TensorFlow.Ops as TF
import qualified TensorFlow.Session as TF
import qualified TensorFlow.Tensor as TF
import qualified TensorFlow.Types as TF

import TensorFlow.Examples.MNIST.InputData
import TensorFlow.Examples.MNIST.Parse

numPixels = 28^2 :: Int64
numLabels = 10 :: Int64

-- | Create tensor with random values where the stddev depends on the width.
randomParam :: Int64 -> TF.Shape -> TF.Build (TF.Tensor TF.Value Float)
randomParam width (TF.Shape shape) =
    (* stddev) <$> TF.truncatedNormal (TF.vector shape)
  where
    stddev = TF.scalar (1 / sqrt (fromIntegral width))

reduceMean xs = TF.mean xs (TF.scalar (0 :: Int32))

-- Types must match due to model structure.
type LabelType = Int32

data Model = Model {
      train :: TF.TensorData Float  -- ^ images
            -> TF.TensorData LabelType
            -> TF.Session ()
    , infer :: TF.TensorData Float  -- ^ images
            -> TF.Session (V.Vector LabelType)  -- ^ predictions
    , errorRate :: TF.TensorData Float  -- ^ images
                -> TF.TensorData LabelType
                -> TF.Session Float
    }

createModel :: TF.Build Model
createModel = do
    -- Use -1 batch size to support variable sized batches.
    let batchSize = -1
    -- Inputs.
    images <- TF.placeholder [batchSize, numPixels]
    -- Hidden layer.
    let numUnits = 500
    hiddenWeights <-
        TF.initializedVariable =<< randomParam numPixels [numPixels, numUnits]
    hiddenBiases <- TF.zeroInitializedVariable [numUnits]
    let hiddenZ = (images `TF.matMul` hiddenWeights) `TF.add` hiddenBiases
    let hidden = TF.relu hiddenZ
    -- Logits.
    logitWeights <-
        TF.initializedVariable =<< randomParam numUnits [numUnits, numLabels]
    logitBiases <- TF.zeroInitializedVariable [numLabels]
    let logits = (hidden `TF.matMul` logitWeights) `TF.add` logitBiases
    predict <- TF.render $ TF.cast $
               TF.argMax (TF.softmax logits) (TF.scalar (1 :: LabelType))

    -- Create training action.
    labels <- TF.placeholder [batchSize]
    let labelVecs = TF.oneHot labels (fromIntegral numLabels) 1 0
        loss =
            reduceMean $ fst $ TF.softmaxCrossEntropyWithLogits logits labelVecs
        params = [hiddenWeights, hiddenBiases, logitWeights, logitBiases]
    grads <- TF.gradients loss params

    let lr = TF.scalar 0.00001
        applyGrad param grad = TF.assign param $ param `TF.sub` (lr * grad)
    trainStep <- TF.group =<< zipWithM applyGrad params grads

    let correctPredictions = TF.equal predict labels
    errorRateTensor <- TF.render $ 1 - reduceMean (TF.cast correctPredictions)

    return Model {
          train = \imFeed lFeed -> TF.runWithFeeds_ [
                TF.feed images imFeed
              , TF.feed labels lFeed
              ] trainStep
        , infer = \imFeed -> TF.runWithFeeds [TF.feed images imFeed] predict
        , errorRate = \imFeed lFeed -> TF.unScalar <$> TF.runWithFeeds [
                TF.feed images imFeed
              , TF.feed labels lFeed
              ] errorRateTensor
        }

main = TF.runSession $ do
    -- Read training and test data.
    trainingImages <- liftIO (readMNISTSamples =<< trainingImageData)
    trainingLabels <- liftIO (readMNISTLabels =<< trainingLabelData)
    testImages <- liftIO (readMNISTSamples =<< testImageData)
    testLabels <- liftIO (readMNISTLabels =<< testLabelData)

    -- Create the model.
    model <- TF.build createModel

    -- Functions for generating batches.
    let encodeImageBatch xs =
            TF.encodeTensorData [genericLength xs, numPixels]
                                (fromIntegral <$> mconcat xs)
    let encodeLabelBatch xs =
            TF.encodeTensorData [genericLength xs]
                                (fromIntegral <$> V.fromList xs)
    let batchSize = 100
    let selectBatch i xs = take batchSize $ drop (i * batchSize) (cycle xs)

    -- Train.
    forM_ ([0..1000] :: [Int]) $ \i -> do
        let images = encodeImageBatch (selectBatch i trainingImages)
            labels = encodeLabelBatch (selectBatch i trainingLabels)
        train model images labels
        when (i `mod` 100 == 0) $ do
            err <- errorRate model images labels
            liftIO $ putStrLn $ "training error " ++ show (err * 100)
    liftIO $ putStrLn ""

    -- Test.
    testErr <- errorRate model (encodeImageBatch testImages)
                               (encodeLabelBatch testLabels)
    liftIO $ putStrLn $ "test error " ++ show (testErr * 100)

    -- Show some predictions.
    testPreds <- infer model (encodeImageBatch testImages)
    liftIO $ forM_ ([0..3] :: [Int]) $ \i -> do
        putStrLn ""
        T.putStrLn $ drawMNIST $ testImages !! i
        putStrLn $ "expected " ++ show (testLabels !! i)
        putStrLn $ "     got " ++ show (testPreds V.! i)
