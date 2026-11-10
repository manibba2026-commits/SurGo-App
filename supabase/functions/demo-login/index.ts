// Supabase Edge Function: demo phone + PIN sign-in.
import { handleDemoLogin } from './handler.ts';

Deno.serve((request) =>
  handleDemoLogin(request, {
    supabaseUrl: Deno.env.get('SUPABASE_URL') ?? '',
    serviceRoleKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
  })
);
