[![DOI](https://img.shields.io/badge/DOI-10.82901%2Fnemar.nm000253-blue)](https://doi.org/10.82901/nemar.nm000253)

# Brain Treebank: large-scale intracranial (iEEG) recordings from naturalistic language stimuli

## Summary

The Brain Treebank is a large-scale dataset of intracranial electrophysiological (iEEG /
stereo-EEG) recordings collected from **10 epilepsy patients** (at Boston Children's
Hospital) while they watched Hollywood movies. Recordings were acquired at **2048 Hz**
from on average **168 electrodes per subject (1,688 electrodes total)**, totalling
roughly **43 hours across 26 trials** (one trial = one movie). The audio of each movie
was transcribed and word onsets manually annotated, and each transcript was parsed into
Universal Dependencies (UD) syntax trees — making this one of the largest datasets of
intracranial recordings grounded in naturalistic language.

This NEMAR record provides the dataset converted to **BIDS-iEEG** (BrainVision) format:
each trial is one BIDS run (`task-movie`, `run-01` …), with signals in `sub-*/ieeg/`.

## Modality and paradigm

- **Modality:** Intracranial EEG / stereo-EEG (iEEG-BIDS), 2048 Hz, BrainVision
  (IEEE_FLOAT_32, multiplexed)
- **Task / paradigm:** Passive naturalistic viewing of Hollywood movies (`task-movie`),
  with time-aligned word-level language annotations (transcripts and UD syntax trees in
  `code/transcripts.zip` and `code/trees.zip`)
- **Population:** 10 epilepsy patients undergoing intracranial monitoring

## Participants and data structure

- **10 subjects** (`sub-01` … `sub-10`), 26 movie-viewing runs in total.
- Electrode labels and per-subject electrode information are in each `sub-*/ieeg/`
  (`electrodes.tsv`, `coordsystem.json`); corrupted electrodes are flagged as `bad` in
  `channels.tsv` (from the Brain Treebank `corrupted_elec.json`).
- Electrode coordinates are provided as-is from the Brain Treebank `localization.zip`
  (`code/localization.zip`); see each `coordsystem.json` for important caveats about
  units and the absence of a published transform to a standard template.

## BaRISTA spatial inputs

The dataset owns the atlas mapping. `electrodes.tsv` now includes
`barista_parcel_index` (121 slots) and `barista_lobe_index` (21 slots).
`electrodes.json` records the pinned upstream source and label-to-index tables.
Index 0 means the source label is missing or outside that table; it is not an
anatomical assignment. Subject 01 has no matched localization and remains unknown.

After loading a recording as `raw`, align the rows to its channel order:

```python
import pandas as pd
from braindecode.models import BaRISTA

electrodes = pd.read_csv("sub-02/ieeg/sub-02_electrodes.tsv", sep="\t")
electrodes = electrodes.set_index("name").loc[raw.ch_names]
model = BaRISTA(
    n_chans=len(raw.ch_names), n_times=6144, n_outputs=2,
    spatial_scale="parcels",
    spatial_indices=electrodes["barista_parcel_index"].tolist(),
)
```

For lobes, use `spatial_scale="lobes"` and `barista_lobe_index`.
For coordinates, use `spatial_scale="coords"` and the integer rows from
`electrodes[["x", "y", "z"]]` as `spatial_indices`, after excluding channels
with missing coordinates from both the recording and the metadata. These are
original L/I/P indices in `[0, 200)`: do not negate, rescale, center or clip
them, or convert them into MNE metre coordinates. No physical-unit or anatomical
transform is inferred. This supplies spatial indices, not pretrained weights.

Regenerate the derived columns with `python code/add_barista_metadata.py`;
validate them without writing with `python code/add_barista_metadata.py --check`.
The script preserves channel names, row order, coordinates and original labels.

## Original dataset / data paper

Please cite the original publication when using this dataset:

> Wang, C., Yaari, A. U., Singh, A. K., Subramaniam, V., Rosenfarb, D., DeWitt, J.,
> Misra, P., Madsen, J. R., Stone, S., Kreiman, G., Katz, B., Cases, I., & Barbu, A.
> (2024). *Brain Treebank: Large-scale intracranial recordings from naturalistic language
> stimuli.* Advances in Neural Information Processing Systems 37 (NeurIPS 2024, Datasets
> and Benchmarks Track). arXiv:2411.08343.

- **Preprint / DOI:** [arXiv:2411.08343](https://doi.org/10.48550/arXiv.2411.08343)
- **NeurIPS 2024 proceedings:** https://proceedings.neurips.cc/paper_files/paper/2024/hash/aefa2385b3f33abf1526ae4e2c208cd9-Abstract-Datasets_and_Benchmarks_Track.html
- **Project site / source data:** https://braintreebank.dev/
- **Original code release:** https://github.com/czlwang/brain_treebank_code_release
- **Ethics:** Boston Children's Hospital / Harvard IRB; all subjects gave informed consent.

## BIDS conversion

Per-trial HDF5 recordings from braintreebank.dev were converted to BIDS-iEEG (BrainVision)
with the EEGDash conversion script in `code/convert_braintreebank.py`. Each trial (one
movie) becomes one BIDS run. EEG-BIDS / MNE-BIDS were used only for standardisation; the
data themselves are from the original Brain Treebank release. Please credit the original
creators (Wang et al.) and cite the paper above.

## License

CC BY 4.0 (see `dataset_description.json`).
