# Pinned by digest: upstream publishes only :latest and :main, so there is no
# version tag to track. src/luckperms-init/seed.py depends on this API's
# measured behaviour, so it must not move without a deliberate re-test.
FROM ghcr.io/luckperms/rest-api@sha256:a8b58f31337f720ef00beb79544dcce266fa4fbf2f1b67ea17d19912c03a0ee0

# The permission model is applied by the luckperms-init service from
# src/luckperms-init/permissions.yml, not by a compiled extension.
