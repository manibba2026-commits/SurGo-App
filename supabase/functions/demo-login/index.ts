// Supabase Edge Function: demo phone + PIN sign-in.
import { handleDemoLogin } from './handler.ts';

// The token exchange only needs a publishable key. New projects expose the
// plural JSON form; older ones still inject SUPABASE_ANON_KEY.
function publishableKey(): string {
  const legacy = Deno.env.get('SUPABASE_ANON_KEY');
  if (legacy) return legacy;
  try {
    const keys = JSON.parse(Deno.env.get('SUPABASE_PUBLISHABLE_KEYS') ?? '{}');
    return typeof keys?.default === 'string' ? keys.default : '';
  } catch {
    return '';
  }
}

Deno.serve((request) =>
  handleDemoLogin(request, {
    supabaseUrl: Deno.env.get('SUPABASE_URL') ?? '',
    serviceRoleKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    publishableKey: publishableKey(),
  })
);
