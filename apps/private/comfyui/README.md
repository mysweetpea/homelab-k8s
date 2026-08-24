# ComfyUI (staged — GPU node required)

**Status: STAGED.** Not deployed yet — the cluster has no GPU.

## When a GPU node joins

1. Label the node: `kubectl label node <name> gpu-node=true`
2. Install NVIDIA device plugin (standard DaemonSet) on that node
3. Apply this directory:
   ```bash
   kubectl apply -f pvc.yaml -f deployment.yaml
   ```
4. Wire into Open WebUI: Admin Settings → Image Generation → engine `comfyui`,
   base URL `http://comfyui.private.svc.cluster.local:8180`

## Notes
- Target GPU: RTX 4070 Ti SUPER class (16GB VRAM) or stronger
- Models PVC: 100Gi Longhorn (single replica — models re-downloadable)
- Open WebUI's `image_generation.comfyui.base_url` config key already exists in DB
