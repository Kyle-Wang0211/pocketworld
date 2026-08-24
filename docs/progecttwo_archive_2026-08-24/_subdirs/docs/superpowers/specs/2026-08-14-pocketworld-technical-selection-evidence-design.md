# PocketWorld Technical Selection Evidence Design

## Objective

Revise the existing Figma technical-selection board without rebuilding its overall layout. The board must withstand academic and interview scrutiny by separating measured evidence, expert judgement, and project-specific decision aggregation.

## Method Structure

The board uses three layers with distinct roles:

1. **Same-condition phone benchmark** supplies quantitative evidence from the same frozen input, physical iPhone, end-to-end pipeline, and delivery target. Raw units remain visible: seconds, MB, RMS, coverage, repeat-success count, and failure state.
2. **Expert survey** elicits criteria, observable value anchors, hard gates, and weights. The intended method is a two-round anonymous Delphi-style survey followed by swing weighting. Until that survey is executed, weights are labelled provisional rather than expert consensus.
3. **Project-specific MCDA** maps raw measures to predeclared 0-100 single-attribute value functions and aggregates them into mobile-delivery utility E and result-delivery utility Q. It is a decision index, not a public benchmark, accuracy percentage, or physical measurement scale.

## Visual Changes

- Preserve the current board, scatter plot, candidate index, algorithm table, and production-chain panel.
- Rename the board to `PocketWorld 技术路线决策地图｜实测 + 专家调查 + 项目自定义 MCDA`.
- Replace the current formula card with a three-stage evidence pipeline: quantitative phone benchmark, expert elicitation, MCDA and hard-gate decision.
- Retain the scatter plot but relabel both axes as anchored project-value indices.
- Label the upper-right area `生产候选区（项目门槛，非统计置信区）`.
- Use filled circles for physical-iPhone evidence, hollow circles for partial/host/literature evidence, diamonds for components, grey for failed gates, blue for active candidates, and red only for the current production chain.
- Keep R22 APDe-MVS outside the plot in a `待测` panel until complete physical-iPhone end-to-end evidence exists.
- Add an evidence-source table that distinguishes quantitative measurements, qualitative expert judgements, and binary hard gates.
- Add compact academic references and explicitly state which elements are project-authored.

## Scale and Weight Semantics

Raw metrics preserve their original units. Each metric is mapped through a predeclared single-attribute value function to anchors 0/20/40/60/80/100. These are project value anchors, not an empirical ratio scale. A one-grade change means moving to the next observable evidence anchor; it does not mean an equal increase in speed, quality, or accuracy.

Current weights are provisional founder decision weights. Final weights are obtained by comparing the value swing from worst to best for each criterion, then normalizing. Expert survey results report median and interquartile range, not invented percentages. Sensitivity analysis varies each weight by plus or minus 20 percent and renormalizes; a changing preferred route or qualified set is labelled weight-sensitive.

## Hard Gates

A route enters the production-candidate region only when `E >= 80`, `Q >= 80`, and all gates pass:

- Same-scope complete route
- Physical iPhone end-to-end run
- Frozen-input repeat success
- No jetsam or thermal termination
- Output opens, edits, and exports
- Licensing and cross-platform constraints resolved

The threshold is a PocketWorld acceptance rule corresponding to the 80-point anchor, not a threshold found in the literature.

## Academic Boundary

The additive model is grounded in Fishburn's additive-utility work and later MCDA literature. ISO/IEC 25010:2023 informs software-product quality dimensions. Delphi literature informs the expert-survey procedure. PocketWorld owns the criteria selection, value functions, weights, hard gates, and threshold.

## Verification

- Export the revised frame at full resolution.
- Confirm no text clipping, overlap, or illegible footnotes.
- Confirm every numerical claim is labelled measured, provisional, or pending.
- Confirm no component or literature-only reference is counted as a qualified full production route.
- Confirm R21 is the only route described as the currently verified production candidate.
