-- =============================================================================
-- Database trigger for unified push notification dispatching via pg_net
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pg_net SCHEMA extensions;

-- Create the trigger function
CREATE OR REPLACE FUNCTION public.handle_notification_insert()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
DECLARE
  dispatch_url TEXT;
  service_key TEXT;
  headers JSONB;
BEGIN
  -- Get custom settings if set (allows configuration per environment)
  dispatch_url := coalesce(
    current_setting('app.settings.push_dispatch_url', true),
    'http://supabase-edge-functions:9000/push-dispatch'
  );
  
  service_key := current_setting('app.settings.service_role_key', true);
  
  IF service_key IS NOT NULL AND service_key <> '' THEN
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || service_key
    );
  ELSE
    headers := jsonb_build_object(
      'Content-Type', 'application/json'
    );
  END IF;

  -- Trigger the push dispatch edge function asynchronously via pg_net
  PERFORM net.http_post(
    url := dispatch_url,
    headers := headers,
    body := jsonb_build_object(
      'type', 'INSERT',
      'table', 'notifications',
      'schema', 'public',
      'record', row_to_json(NEW)::jsonb
    ),
    timeout_milliseconds := 5000
  );

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Bind the trigger to notifications AFTER INSERT
DROP TRIGGER IF EXISTS on_notification_created ON public.notifications;
CREATE TRIGGER on_notification_created
  AFTER INSERT ON public.notifications
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_notification_insert();
