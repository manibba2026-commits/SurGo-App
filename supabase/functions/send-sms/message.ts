/**
 * The single SMS body SurGo sends for a Supabase-generated OTP.
 *
 * UniSMS enforces the Philippine OTP content format: it must carry the brand
 * name, the code, the purpose and an expiration. A message that does not
 * follow the format is accepted with HTTP 201 and then rejected asynchronously
 * (`fail_reason: "Unacceptable content: OTP does not follow valid format"`),
 * so the wording below is load-bearing. Do not shorten it or change the order.
 *
 * Keep "Expires in 1 minute." in sync with Auth's `sms_otp_exp`, which is 60
 * seconds on the hosted project.
 */
export function buildOtpMessage(otp: string): string {
  return `Your SurGo OTP code is ${otp}. Please do not share. Expires in 1 minute.`;
}
