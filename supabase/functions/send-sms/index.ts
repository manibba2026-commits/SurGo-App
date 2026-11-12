// Supabase Edge Function: Send SMS hook → configured SMS provider.
//
// Auth owns the OTP; this endpoint only delivers it. Requests must be signed
// with the Standard Webhooks secret configured in Auth → Hooks → Send SMS.
import { handleSendSms } from './handler.ts';

Deno.serve((request) =>
  handleSendSms(request, {
    hookSecret: Deno.env.get('SEND_SMS_HOOK_SECRET') ?? '',
    smsProvider: Deno.env.get('SMS_PROVIDER'),
    semaphoreApiKey: Deno.env.get('SEMAPHORE_API_KEY') ?? '',
    semaphoreSenderName: Deno.env.get('SEMAPHORE_SENDER_NAME') || undefined,
    unisms: {
      accessKeyId: Deno.env.get('UNISMS_ACCESS_KEY_ID') ?? '',
      accessKeySecret: Deno.env.get('UNISMS_ACCESS_KEY_SECRET'),
      signature: Deno.env.get('UNISMS_SIGNATURE') ?? '',
      templateId: Deno.env.get('UNISMS_TEMPLATE_ID') ?? '',
      codeVariable: Deno.env.get('UNISMS_CODE_VARIABLE'),
      authMode: Deno.env.get('UNISMS_AUTH_MODE'),
    },
  })
);
