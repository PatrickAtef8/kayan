# اختبار المتصفح للإشعارات (Chromium حقيقي)

يشغّل: Next.js (production) + **PostgREST الحقيقي** على قاعدة بيانات الـ migrations الحقيقية + Chromium، ويجرّب الأدوار الثلاثة
(مالك / أمين مخزن / مندوب ×2): الـ Red Dot، العدّاد، القراءة، تحديد الكل، التحديث اللحظي بدون Refresh، انقطاع الاتصال والتعويض،
إعادة محاولة الإشعار الفاشل، وتخطيط الموبايل.

**ما هو بديل (mock) هنا وليس Supabase الحقيقي:** خدمة الدخول (GoTrue) والـ WebSocket الخاص بـ Realtime (`mock.mjs`).
الـ mock بيقرر مين يستلم الحدث بتشغيل **نفس سياسة RLS الحقيقية** على كل تغيير، لكنه **لا يختبر** نشر الـ WAL ولا
publication ولا خدمة Realtime نفسها — دي لازم تتجرب على Supabase الحقيقي (قائمة الفحص اليدوي في `CHANGES-notifications.md`).

التشغيل (يحتاج Postgres 15+ محلي، PostgREST، وحزم node: `puppeteer-core @sparticuz/chromium pg ws jsonwebtoken`):
تم تشغيله هنا عبر `run.sh` بعد نسخ الملفات لمجلد عمل فيه `npm i` للحزم أعلاه؛ عدّل المسارات في `run.sh` حسب جهازك.
