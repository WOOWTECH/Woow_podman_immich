# Deployment reliability

The pinned Immich 2.7.5 ML image uses Gunicorn 25.1.0. Its control socket can deadlock startup. New example settings include GUNICORN_CMD_ARGS=--no-control-socket. Existing environment files are preserved: add that flag to any existing GUNICORN_CMD_ARGS, then rerun the installer in a maintenance window. Do not replace custom arguments. Keep server/ML image versions matched; do not remove the model cache. Recheck /ping from the server and run a real local /predict inference. The observed fix returned 512 finite, nonzero CLIP embedding values without reading customer photos. [Upstream issue](https://github.com/immich-app/immich/issues/27228).

[Existing N100 deployment and functional evidence](https://github.com/WOOWTECH/Woow_ubuntu_version_control/blob/195dcda9357100a7821407e1c8469a349acc9831/distribution/docs/reboot-acceptance.md). Source fixes do not themselves restart an existing installation.
