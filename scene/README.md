# scene/ — the only thing to change when swapping the clip

- `prompt.json`: the image-to-video prompt in the Cosmos3-Nano JSON format. The current file is the model card's example image-to-video prompt (coastal road).
- `scene.env`: `SCENE_NAME`, `INPUT_IMAGE_URL`, optional `INPUT_IMAGE_SHA256` (the run fails if the downloaded image doesn't match), `SEED`. All non-secret.

The input image is referenced by URL only and is not stored in this repo. The default image comes from the Cosmos3-Nano model repository, which declares `license_name: openmdw1.1-license`; the image has no separate license or provenance note, so its standalone redistribution terms are unverified. Use an image you are allowed to use.
