# Dangg backend — Supabase Edge Runtime container
#
# Serves all Edge Functions at /functions/v1/{name}
# Build: docker build -t dangg-backend .
# Run:   docker run -p 8000:8000 --env-file .env dangg-backend
FROM supabase/edge-runtime:v1.67.4

# Copy Edge Functions (migrations / seed / docs stay out)
COPY supabase/functions /usr/services/functions

ENV FUNCTIONS_PATH=/usr/services/functions
ENV APP_ENV=production

EXPOSE 8000

CMD ["start", "--main-service", "/usr/services/functions/_main", "--port", "8000"]
