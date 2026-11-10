import { createClient } from '@supabase/supabase-js';

/**
 * Service-role client. Only import this from server-only code (route handlers);
 * never from a Client Component. The key is read at call time, so a build does
 * not need it, and it is never sent to the browser.
 */
export function createServiceClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    throw new Error('SUPABASE_SERVICE_ROLE_KEY is not configured on the server.');
  }
  return createClient(url, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}
