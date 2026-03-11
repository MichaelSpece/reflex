# Split-runtime export (Python-only and Node-only stages)

This example shows how to split the export pipeline into separate Docker stages so
that each build stage installs only one runtime:

- **Python stage**: compiles the Reflex app and prepares backend artifacts.
- **Node stage**: installs frontend dependencies and builds static assets.
- **Runtime stage**: runs only Python, Caddy, and Redis in production.

The key idea is to call the lower-level build steps directly:

1. Use Python to compile the app and generate `.web` sources.
2. Copy `.web` into a Node stage and run `npm run export`.
3. Copy frontend build output into the runtime image.

> This pattern avoids installing Node.js in Python build/runtime stages and avoids
> installing Python in the Node build stage.

## Build and run

From your app root:

```bash
docker build -f docker-example/export-split-runtime/Dockerfile -t reflex-split-export .
docker run --rm -p 8080:8080 reflex-split-export
```

## Notes

- Set `API_URL` at build time if your backend URL is different from
  `http://localhost:$PORT`.
- The example runs `reflex db migrate` on startup when `alembic/` exists.
- If you already export frontend assets in CI, you can skip the Node stage and
  copy your prebuilt `build/client` directory directly into `/srv`.

## FAQ

### Does Stage 1 need to run on a specific platform?

Usually, **no**: Stage 1 only uses Python to initialize/compile Reflex and then
passes the generated `.web` sources to Stage 2, so there is no binary artifact
from Stage 1 copied into the final image in this example.

Still, keep these practical constraints in mind:

- Use a Python version compatible with your app and Reflex.
- Stage 1 must be able to install and import your app dependencies (some may
  need OS packages during build).
- When building for multiple architectures, prefer `docker buildx build` so
  each stage is resolved for the target platform consistently.

### Can Stage 2 copy only `.web` files that are not ignored by `.web/.gitignore`?

Usually **yes**, because ignored paths in `.web/.gitignore` are typically
generated artifacts (for example `node_modules/` and `build/`) that Stage 2
recreates with `npm ci` and `npm run export`.

That said, copying the full `.web` directory from Stage 1 is the most robust
default: Reflex may add new required files over time, and a filtered copy can
accidentally omit something the frontend build needs.
