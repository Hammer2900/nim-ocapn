# Specification Baseline

Checked: **2026-11-18**. The baseline is pinned by Git commit, file path, and
content hash; `main` alone is not used as a version identifier. Both local
checkouts matched the corresponding published `HEAD` at the time of checking.

| Document | Repository | Commit | Path | SHA-256 | Status |
|---|---|---|---|---|---|
| CapTP Specification | `https://github.com/ocapn/ocapn` | `ebf68742a40a89fff4730886a8788c5fe1bc9b96` | `draft-specifications/CapTP Specification.md` | `c916ddb1f9cf22ce442fb0f944b90e6bb2fd6cf11cbe769c5dda96c8972bd705` | Draft |
| Locators | `https://github.com/ocapn/ocapn` | `ebf68742a40a89fff4730886a8788c5fe1bc9b96` | `draft-specifications/Locators.md` | `a6e1e3434b8f6efa85f71cb1601db38e72c5e4f91d00d838828d122c617c7658` | Draft |
| Netlayers | `https://github.com/ocapn/ocapn` | `ebf68742a40a89fff4730886a8788c5fe1bc9b96` | `draft-specifications/Netlayers.md` | `6f49dc5b2da6d5dc1c18985b715bec14913c6cb41a54e037d01ff20cb3789ad2` | Draft |
| Model | `https://github.com/ocapn/ocapn` | `ebf68742a40a89fff4730886a8788c5fe1bc9b96` | `draft-specifications/Model.md` | `fd200feec75765d2b7ce5b65e602a9c91ac20b42b52ba59b5fddeb91f47f36a9` | Draft reference |
| Notation | `https://github.com/ocapn/ocapn` | `ebf68742a40a89fff4730886a8788c5fe1bc9b96` | `draft-specifications/Notation.md` | `66779ddd506a15717d6d0e52409dee6f72219d3ce75f5d9e407d47dec21fb591` | Draft reference |
| Syrup Specification | `https://github.com/ocapn/syrup` | `931fa528b8ddda976febba577fb09ee0726845d4` | `draft-specification.md` | `6cbb7014a1ad557483ad18416e07448850ed106b2867c8136b25fd3249124374` | Draft |

## Revision evidence

```text
git -C ../ocapn rev-parse HEAD  -> ebf68742a40a89fff4730886a8788c5fe1bc9b96
git -C ../syrup rev-parse HEAD  -> 931fa528b8ddda976febba577fb09ee0726845d4
git ls-remote https://github.com/ocapn/ocapn.git HEAD -> ebf68742a40a89fff4730886a8788c5fe1bc9b96
git ls-remote https://github.com/ocapn/syrup.git HEAD -> 931fa528b8ddda976febba577fb09ee0726845d4
```

The CapTP draft depends on Syrup for all wire values, Netlayers for a secure
reliable channel, and Locators for in-band/out-of-band peer and sturdyref
representations. Locators in turn depend on Syrup and RFC 3986 URI syntax.
Model and Notation define shared passable-value and notation terms.

The baseline is intentionally a draft profile. A future release must replace
these hashes with a reviewed/published revision or explicitly retain this
baseline as its compatibility contract.
