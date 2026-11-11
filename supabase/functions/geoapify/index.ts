import { createGeoapifyHandler, verifySupabaseUser } from './handler.ts';

// Server environment only. No client-provided URLs/keys, service-role key,
// database access, or decoding a JWT subject as proof of identity.
const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const handler = createGeoapifyHandler({
  apiKey: Deno.env.get('GEOAPIFY_API_KEY') ?? '',
  authenticate: (token, signal) => verifySupabaseUser(token, signal, { supabaseUrl, anonKey }),
});

Deno.serve(handler);
