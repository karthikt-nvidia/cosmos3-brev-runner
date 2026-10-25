# Third-party notices

This repository contains only scripts and a text prompt. It does not include model weights, container images or the input image; they are downloaded at run time from their sources and are governed by their own terms.

- **NVIDIA Cosmos3-Nano** (`nvidia/Cosmos3-Nano`, https://huggingface.co/nvidia/Cosmos3-Nano): the model repository declares `license: other`, `license_name: openmdw1.1-license` (https://openmdw.ai/license/1-1/). Review those terms before use.
- **`scene/prompt.json`**: the model card's example image-to-video prompt (`assets/example_i2v_prompt.json` in the model repository), included as the default scene; same terms as the model repository.
- **Negative prompt**: read at run time from the downloaded model snapshot (`assets/negative_prompt.json`); not included here.
- **Default input image**: referenced by URL only (see `README.md`); standalone redistribution terms unverified; not included.
- **vLLM-Omni container** (`vllm/vllm-omni`, pinned by digest): see the vLLM-Omni project for its license.
- **NVIDIA Cosmos-1.0-Guardrail**: not used (`--no-guardrails`); gated.
