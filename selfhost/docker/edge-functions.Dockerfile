# Edge runtime with the functions BAKED IN.
#
# The old setup bind-mounted ./volumes/functions into the container. On Dokploy
# that bind mount kept getting recreated empty (and once left a dangling
# deleted-inode mount), taking the whole edge layer down. Baking the functions
# into the image removes the moving part entirely — a redeploy rebuilds the
# image from the repo, so the functions can never go missing.
#
# Updating functions now = redeploy (rebuilds this image from git). Local dev
# still hot-edits via the bind mount added back in docker-compose.localdev.yml.
FROM supabase/edge-runtime:v1.74.0

COPY volumes/functions /home/deno/functions
