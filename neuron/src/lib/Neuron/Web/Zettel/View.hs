{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Neuron.Web.Zettel.View
  ( renderZettel,
    renderZettelContentCard,
  )
where

import Data.TagTree
import Data.Tree
import qualified Neuron.Web.Query.View as Q
import Neuron.Web.Route
import Neuron.Web.Widget
import qualified Neuron.Web.Widget.AutoScroll as AS
--import qualified Neuron.Web.Widget.InvertedTree as IT
import Neuron.Web.ZIndex (connIndicators)
import Neuron.Zettelkasten.Connection
import Neuron.Zettelkasten.Graph (ZettelGraph)
import qualified Neuron.Zettelkasten.Graph as G
import Neuron.Zettelkasten.Query.Error (QueryError, showQueryError)
import qualified Neuron.Zettelkasten.Query.Eval as Q
import Neuron.Zettelkasten.Zettel
import Reflex.Dom.Core hiding ((&))
import Reflex.Dom.Pandoc
import Relude hiding ((&))
import Text.Pandoc.Definition (Pandoc)

-- | TODO: Move date creation out of it, like ZIndex
renderZettel ::
  PandocBuilder t m =>
  (ZettelGraph, ZettelC) ->
  NeuronWebT t m ()
renderZettel (graph, zc@(sansContent -> z)) = do
  --let upTree = G.backlinkForest Folgezettel z graph
  --unless (null upTree) $ do
  --  IT.renderInvertedHeadlessTree "zettel-uptree" "deemphasized" upTree $ \z2 ->
  --    Q.renderZettelLink (G.getConnection z z2 graph) def z2
  -- Main content
  elAttr "div" ("class" =: "ui text container" <> "id" =: "zettel-container" <> "style" =: "position: relative") $ do
    divClass "ui left attached rail" $ do
      divClass "ui segment" $ do
        elClass "ul" "uplink-tree deemphasized" $ do
          let upTree2 = G.backlinkForest2 Folgezettel z graph
          renderUplinkForest z graph upTree2
          let cfBacklinks = nonEmpty $ fmap snd $ G.backlinks (== Just OrdinaryConnection) z graph
          whenJust cfBacklinks $ \zs -> do
            el "li" $ do
              el "hr" blank
              text "Non-branching backlinks"
              -- TODO: eject folgezettel parents from `zs`
              el "ul" $ forM_ zs $ \cfZ ->
                el "li" $ Q.renderZettelLink Nothing def cfZ
    whenStaticallyGenerated $ do
      -- We use -24px (instead of -14px) here so as to not scroll all the way to
      -- title, and as to leave some of the tree visible as "hint" to the user.
      lift $ AS.marker "zettel-container-anchor" (-24)
    divClass "zettel-view" $ do
      renderZettelContentCard (graph, zc)

-- Because the tree above can be pretty large, we scroll past it
-- automatically when the page loads.
--whenStaticallyGenerated $ do
--  unless (null upTree) $ do
--    AS.script "zettel-container-anchor"

renderUplinkForest :: DomBuilder t m => Zettel -> ZettelGraph -> Forest Zettel -> NeuronWebT t m ()
renderUplinkForest currentZettel g trees = do
  forM_ trees $ \(Node zettel subtrees) ->
    el "li" $ do
      let branchesToCurrentZettel = (== Just Folgezettel) $ G.getConnection zettel currentZettel g
      elClass "span" (bool "remote" "terminal alwaysemph" branchesToCurrentZettel) $ do
        Q.renderZettelLink Nothing def zettel
        -- TODO: Do it the *other* way. Inject child as non-link text under the secondary parents.
        connIndicators $ fmap snd $ G.backlinks (== Just Folgezettel) zettel g
      unless (null subtrees) $ do
        el "ul" $ renderUplinkForest currentZettel g subtrees

renderZettelContentCard ::
  PandocBuilder t m =>
  (ZettelGraph, ZettelC) ->
  NeuronWebT t m ()
renderZettelContentCard (graph, zc) =
  case zc of
    Right z ->
      renderZettelContent (evalAndRenderZettelQuery graph) z
    Left z -> do
      renderZettelRawContent z

-- TODO: remove
_renderZettelBottomPane :: DomBuilder t m => ZettelGraph -> Zettel -> NeuronWebT t m ()
_renderZettelBottomPane graph z@Zettel {..} = do
  let cfBacklinks = nonEmpty $ fmap snd $ G.backlinks (== Just OrdinaryConnection) z graph
      tags = nonEmpty zettelTags
  when (isJust cfBacklinks || isJust tags)
    $ elClass "nav" "ui bottom attached segment deemphasized"
    $ do
      divClass "ui two column grid" $ do
        divClass "column" $ do
          whenJust cfBacklinks $ \links -> do
            elAttr "div" ("class" =: "ui header" <> "title" =: "Zettels that link here, but without branching") $
              text "More backlinks"
            el "ul" $ do
              forM_ links $ \zl ->
                el "li" $ Q.renderZettelLink Nothing def zl
        whenJust tags $
          divClass "column" . renderTags

evalAndRenderZettelQuery ::
  PandocBuilder t m =>
  ZettelGraph ->
  NeuronWebT t m [QueryError] ->
  URILink ->
  NeuronWebT t m [QueryError]
evalAndRenderZettelQuery graph oldRender uriLink = do
  case flip runReaderT (G.getZettels graph) (Q.runQueryURILink uriLink) of
    Left e -> do
      -- Error parsing or running the query.
      fmap (e :) oldRender <* elInlineError e
    Right Nothing -> do
      -- This is not a query link; pass through.
      oldRender
    Right (Just res) -> do
      Q.renderQueryResult res
      pure mempty
  where
    elInlineError e =
      elClass "span" "ui left pointing red basic label" $ do
        text $ showQueryError e

renderZettelContent ::
  forall t m a.
  (PandocBuilder t m, Monoid a) =>
  (NeuronWebT t m a -> URILink -> NeuronWebT t m a) ->
  ZettelT Pandoc ->
  NeuronWebT t m ()
renderZettelContent handleLink Zettel {..} = do
  elClass "article" "ui raised attached segment zettel-content" $ do
    unless zettelTitleInBody $ do
      el "h1" $ text zettelTitle
    void $ elPandoc (Config handleLink) zettelContent
    whenJust zettelDay $ \day ->
      elAttr "div" ("class" =: "date" <> "title" =: "Zettel creation date") $ do
        text "Created on: "
        elTime day
    whenJust (nonEmpty zettelTags) $ renderTags

renderZettelRawContent :: (DomBuilder t m) => ZettelT Text -> m ()
renderZettelRawContent Zettel {..} = do
  divClass "ui error message" $ do
    elClass "h2" "header" $ text "Zettel failed to parse"
    el "p" $ el "pre" $ text $ show zettelError
  elClass "article" "ui raised attached segment zettel-content raw" $ do
    el "pre" $ text $ zettelContent

renderTags :: DomBuilder t m => NonEmpty Tag -> m ()
renderTags tags = do
  forM_ tags $ \t -> do
    -- NOTE(ui): Ideally this should be at the top, not bottom. But putting it at
    -- the top pushes the zettel content down, introducing unnecessary white
    -- space below the title. So we put it at the bottom for now.
    elAttr "span" ("class" =: "ui right ribbon label zettel-tag" <> "title" =: "Tag") $ do
      elAttr
        "a"
        ( "href" =: (Q.tagUrl t)
            <> "class" =: "tag-inner"
            <> "title" =: ("See all zettels tagged '" <> unTag t <> "'")
        )
        $ text
        $ unTag t
    el "p" blank
