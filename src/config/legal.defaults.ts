// The SHIPPED text of the three legal documents (version 1) — original drafts written for Kayan's actual business model, in Arabic and
// English. They are loaded into the database by migration 0065 (generated from this file by scripts/gen-legal-seed.mjs) and from then on
// the Super Admin edits them in /admin/legal (every save is a new immutable version).
//
// Syntax: a small Markdown subset (## / ### headings, "- " and "1. " lists, "> " call-outs, **bold**, [text](url)).
// Placeholders filled from the admin's legal settings: {{company_name}} {{phone}} {{email}} {{address}} {{commercial_register}}
// {{tax_registration}}.
// [[REVIEW: …]] marks a clause or assumption an Egyptian lawyer must confirm. It is NEVER shown on the public pages; it is listed for
// the admin in /admin/legal and in docs/LEGAL_REVIEW.md.
//
// IMPORTANT: these are drafts, not legal advice. They describe what Kayan actually does today (see docs/LEGAL_REVIEW.md for the facts they
// rest on) and make no guarantee the product does not give.

export type LegalKey = "terms" | "privacy" | "refund";
export type LegalDefault = { titleAr: string; bodyAr: string; titleEn: string; bodyEn: string };

const TERMS_AR = `
هذه الشروط والأحكام ("الشروط") اتفاق بين **{{company_name}}** ("كيان" أو "نحن") وبين الشركة أو الجهة أو الشخص الذي ينشئ حسابًا على منصة كيان ("العميل" أو "أنت"). باستخدامك المنصة أو بإتمام عملية شراء، تقرّ بأنك قرأت هذه الشروط وسياستي الخصوصية والإلغاء والاسترداد ووافقت عليها.

[[REVIEW: يجب تحديد الاسم القانوني الكامل للجهة المشغّلة وسجلها التجاري وبطاقتها الضريبية وعنوانها في إعدادات «الصفحات القانونية»، ومراجعة ما إذا كانت الجهة شركة أم نشاطًا فرديًا.]]

## 1. التعريفات
- **المنصة**: نظام كيان لإدارة الأعمال المقدَّم كخدمة عبر الإنترنت (SaaS)، ويشمل الواجهات والتقارير والتحديثات.
- **الحساب**: حساب الشركة على المنصة ومعه مستخدموها.
- **المالك**: المستخدم الذي أنشأ الحساب أو أُسند إليه دور «مالك»، وهو المسؤول عن الاشتراك والدفع.
- **الباقة**: مجموعة الوحدات والحدود (عدد أعضاء الفريق والمخازن) المعروضة في صفحة الأسعار.
- **الرخصة الدائمة** و**الاشتراك الشهري**: خياران للدفع موضحان في البند 6.
- **بيانات العميل**: كل ما تُدخله أو يُدخله فريقك في المنصة (عملاء، موردون، أصناف، فواتير، مدفوعات، مصروفات وغيرها).

## 2. وصف الخدمة
تقدّم المنصة أدوات لإدارة المبيعات والمشتريات والمخزون والخزينة والعملاء والموردين والمندوبين والعمولات والتقارير بالعربية وبالجنيه المصري. تختلف الوحدات المتاحة باختلاف الباقة. نطوّر المنصة باستمرار وقد نضيف مزايا أو نعدّل أو نوقف بعضها؛ ولن نقلّل الوحدات والحدود التي دفعت مقابلها إلا بموافقتك أو وفق ما يسمح به القانون.

## 3. إنشاء الحساب والأهلية
- يجب أن يكون المستخدم بالغًا ومخوّلًا بالتعاقد باسم الشركة أو الجهة التي يمثلها، وأن يكون استخدامه لأغراض عمل مشروعة.
- أنت مسؤول عن صحة البيانات التي تقدمها وعن تحديثها، وعن سرية كلمة المرور وعن كل نشاط يتم عبر حسابك.
- يحق لنا رفض إنشاء حساب أو تعليقه عند الاشتباه في بيانات غير صحيحة أو استخدام مخالف.

## 4. المستخدمون والأدوار
يتيح الحساب ثلاثة أدوار: المالك والمندوب وأمين المخزن، بصلاحيات مختلفة. المالك مسؤول عن دعوة المستخدمين وعن صلاحياتهم، وعن التزامهم بهذه الشروط، وعن إلغاء وصول من تنتهي علاقته بالشركة. نحن لسنا طرفًا في العلاقة بين الشركة وموظفيها.

## 5. الباقات والحدود والوحدات
تحدّد الباقة الوحدات المتاحة وعدد أعضاء الفريق والمخازن النشطة. تُمنع الإضافات التي تتجاوز حدود باقتك، دون حذف أي بيانات موجودة. تغيير الباقة بعد الشراء غير متاح آليًا حاليًا، ويتم بالتواصل معنا وفق ما نتفق عليه كتابة.
[[REVIEW: سياسة الترقية/التخفيض والتسوية المالية عند تغيير الباقة غير مطبّقة في النظام؛ يجب تحديدها تجاريًا قبل الوعد بها.]]

## 6. خياران للدفع
**أ) الرخصة الدائمة.** تدفع مبلغ الرخصة مرة واحدة، وهو حق استخدام المنصة بالباقة المختارة، وليس نقل ملكية البرنامج أو شيفرته المصدرية. تُقدَّم المنصة مستضافة لدينا، ولذلك تُدفع **الاستضافة والصيانة** شهريًا وبشكل منفصل (مع أول دفعة يشمل السعر عادةً شهر الاستضافة الأول كما يظهر في ملخص الطلب). الرخصة نفسها لا تنتهي بانتهاء الاستضافة، لكن **الدخول إلى الخدمة المستضافة** يتوقف عند انتهاء الفترة المدفوعة وفترة السماح، ويعود فور دفع التجديد.

**ب) الاشتراك الشهري.** سعر شهري واحد شامل للدخول والاستضافة والصيانة، ويمتد كل شهر مدفوع بمدة شهر من تاريخ انتهاء الفترة الحالية (أو من تاريخ الدفع إن كانت قد انتهت).

الأسعار المعروضة في صفحة الأسعار وقت الشراء هي التي تُطبَّق على طلبك، وتُحفظ في الطلب. تغيير الأسعار لاحقًا لا يغيّر طلبًا مدفوعًا ولا يرتّب علينا رد فروق.
[[REVIEW: صياغة «الرخصة الدائمة» مع إيقاف الدخول عند انتهاء الاستضافة تحتاج مراجعة قانونية وتجارية للتأكد من أنها لا تُفهم على أنها إخلال بحق الاستخدام الدائم.]]

## 7. الدفع عبر XPay
- تتم المدفوعات عبر بوابة **XPay** على صفحة دفع آمنة تابعة لها. **لا تمرّ بيانات بطاقتك بخوادم كيان ولا نخزّنها.**
- لا نخصم أي مبلغ تلقائيًا ولا نجدّد تلقائيًا: كل شهر هو دفعة مستقلة يبدؤها المالك بنفسه.
- لا تُفعَّل الباقة أو التجديد إلا بعد **تأكيد الدفع من بوابة الدفع** والتحقق من مطابقة المبلغ للطلب. الوصول إلى صفحة النجاح لا يكفي بذاته، وقد يتأخر التأكيد لحظات.
- تنطبق شروط XPay وبنك مُصدر البطاقة على عملية الدفع نفسها، ولا نتحمل مسؤولية أعطالها خارج نطاق سيطرتنا.

## 8. الضرائب والفواتير
الأسعار بالجنيه المصري كما هي معروضة في ملخص الطلب. نصدر فاتورة أو إيصالًا بالدفع وفق القوانين المعمول بها. إن لزمت ضريبة القيمة المضافة أو أي ضريبة أخرى فتُبيَّن في الفاتورة وفق وضعنا الضريبي.
[[REVIEW: لا يعرض النظام حاليًا سطر ضريبة قيمة مضافة منفصلًا. يجب حسم وضع التسجيل في ضريبة القيمة المضافة (14% على الخدمات الإلكترونية) والفاتورة الإلكترونية لدى مصلحة الضرائب المصرية، وهل الأسعار المعروضة شاملة الضريبة.]]

## 9. المدة والتجديد وفترة السماح والإيقاف
- يبدأ الوصول عند تأكيد الدفع، ويستمر حتى نهاية الفترة المدفوعة.
- بعد انتهاء الفترة المدفوعة تُمنح **فترة سماح** مدتها تحددها المنصة (وتظهر لك مدتها المتبقية في تنبيه دائم أثناء الاستخدام). خلالها يستمر الاستخدام الطبيعي مع تنبيه التجديد.
- بعد انتهاء فترة السماح **يتوقف الدخول** إلى الحساب وبياناته حتى يُؤكَّد دفع تجديد. الدفع المعلّق أو الفاشل أو الملغي لا يعيد الوصول.
- لا نحذف بياناتك تلقائيًا بمجرد انتهاء الاشتراك؛ انظر البند 10.
- مدة فترة السماح قابلة للتعديل من إدارة المنصة، وقد تكون صفرًا.

## 10. بيانات العميل
- **بياناتك ملكك.** نحن نعالجها فقط لتقديم الخدمة لك، وكما توضح [سياسة الخصوصية](/privacy).
- أنت مسؤول عن مشروعية البيانات التي تدخلها (ومنها بيانات عملائك وموردينك) وعن الحصول على أي موافقات لازمة منهم.
- يمكنك تصدير التقارير والفواتير بصيغتي Excel وPDF من المنصة. ويمكنك طلب نسخة من بياناتك أو حذفها بطلب كتابي إلى بيانات التواصل أدناه.
[[REVIEW: يجب تحديد مدة الاحتفاظ بالبيانات بعد انتهاء الاشتراك وموعد حذفها، وآلية التسليم والمدة التي نلتزم بها لطلبات التصدير. لا توجد في النظام سياسة حذف تلقائي مطبّقة اليوم.]]

## 11. الاستخدام المقبول
يُحظر: استخدام المنصة لغرض غير مشروع أو مخالف للقانون المصري؛ محاولة الوصول إلى بيانات شركة أخرى أو تجاوز صلاحياتك أو عزل البيانات؛ الهندسة العكسية أو نسخ المنصة أو إعادة بيعها؛ تحميل برمجيات خبيثة أو إرهاق الخدمة؛ مشاركة بيانات الدخول مع غير المخوّلين. يحق لنا تعليق الوصول عند مخالفة جسيمة مع إخطارك متى أمكن.

## 12. الملكية الفكرية
المنصة وتصميمها ونصوصها وشيفرتها وعلامة «كيان» ملك لنا أو لمرخّصيها. لا تمنحك هذه الشروط إلا حق استخدام المنصة وفق الباقة المختارة، وهو حق غير حصري وغير قابل للتنازل أو الترخيص من الباطن.

## 13. التوافر والدعم والصيانة
نبذل عناية معقولة لإبقاء المنصة متاحة وآمنة، وقد تتوقف أحيانًا للصيانة أو لأسباب خارجة عن إرادتنا (مزوّدو الاستضافة والاتصالات). **لا نقدّم التزامًا بنسبة توافر محددة** ما لم نتفق على ذلك كتابة. تشمل «الصيانة» إصلاح الأخطاء البرمجية وتحديثات الأمان الضرورية، ولا تشمل تطوير ميزات أو تقارير مخصصة أو ترحيل بيانات من نظام آخر أو تدريب الفريق.

## 14. حدود المسؤولية
- المنصة أداة مساعدة لإدارة الأعمال؛ **أنت مسؤول عن مراجعة أرقامك وقراراتك المحاسبية والضريبية**، ولا تُغني المنصة عن محاسب أو مستشار.
- في الحدود التي يسمح بها القانون، لا نسأل عن الأرباح الفائتة أو الأضرار غير المباشرة، وتقتصر مسؤوليتنا الإجمالية عن أي مطالبة على ما دفعته لنا فعليًا في الاثني عشر شهرًا السابقة للواقعة.
- لا يستبعد هذا البند أي مسؤولية لا يجوز استبعادها قانونًا، ومنها المسؤولية عن الغش أو الخطأ الجسيم.
[[REVIEW: الحد الأقصى للمسؤولية (12 شهرًا) افتراض تجاري. في القانون المدني المصري لا يصح الاتفاق على الإعفاء من المسؤولية عن الغش أو الخطأ الجسيم، وللقاضي سلطة تعديل الشروط التعسفية في عقود الإذعان (المادة 149). راجع الصياغة مع محامٍ.]]

## 15. الإلغاء والاسترداد
يحكمهما [سياسة الإلغاء والاسترداد](/refund-policy) وهي جزء لا يتجزأ من هذه الشروط. لا يخلّ ذلك بأي حق مقرر لك بموجب القانون.

## 16. التعليق والإنهاء
- يمكنك التوقف عن استخدام المنصة في أي وقت بعدم التجديد، ولا تُسحب منك أي مبالغ تلقائيًا.
- يجوز لنا تعليق الحساب أو إنهاؤه عند مخالفة جسيمة لهذه الشروط أو الاستخدام غير المشروع، مع إخطارك قدر الإمكان.
- لا يؤثر الإنهاء على الحقوق والالتزامات التي نشأت قبله.

## 17. تعديل الشروط
قد نعدّل هذه الشروط. نعلن النسخة الجديدة بتاريخها ورقمها في هذه الصفحة، ونطلب موافقتك على النسخة الحالية عند كل عملية دفع جديدة. التعديل لا يسري بأثر رجعي على طلب دفعته.
[[REVIEW: هل يكفي الإعلان في الصفحة، أم يلزم إخطار العملاء الحاليين بالبريد الإلكتروني وإتاحة حق الاعتراض/الإنهاء عند التعديل الجوهري؟]]

## 18. القبول الإلكتروني وسجل الموافقة
عند بدء الدفع تؤكد بوضع علامة الموافقة أنك قرأت هذه الشروط وسياستي الخصوصية والإلغاء والاسترداد. نسجّل مع طلبك **أرقام النسخ التي وافقت عليها وتاريخ الموافقة ووقتها** وبيانات تقنية (عنوان الشبكة ونوع المتصفح) كدليل على الموافقة.
[[REVIEW: تأكد من كفاية هذا الإثبات الإلكتروني وفق قانون التوقيع الإلكتروني رقم 15 لسنة 2004، ومن أن جمع عنوان الشبكة ونوع المتصفح كدليل يتوافق مع قانون حماية البيانات الشخصية.]]

## 19. القانون الواجب التطبيق والاختصاص
تخضع هذه الشروط لقوانين جمهورية مصر العربية، وتختص محاكم **[القاهرة]** بنظر أي نزاع ينشأ عنها، دون الإخلال بحق العميل في اللجوء إلى الجهات المختصة المقررة قانونًا (ومنها جهاز حماية المستهلك إن انطبق قانون حماية المستهلك).
[[REVIEW: اختيار المحكمة (القاهرة؟) أو التحكيم، وانطباق قانون حماية المستهلك رقم 181 لسنة 2018 على عملاء من الشركات.]]

## 20. أحكام عامة
- النسخة العربية هي المرجع عند أي اختلاف بينها وبين الترجمة الإنجليزية.
- إذا تبيّن بطلان بند فلا يؤثر ذلك في بقية البنود.
- لا يُعدّ تأخرنا في استعمال حق تنازلًا عنه. لا نسأل عن التأخير الناتج عن قوة قاهرة.
- هذه الشروط مع سياستي الخصوصية والإلغاء والاسترداد هي الاتفاق الكامل بيننا بشأن المنصة.
[[REVIEW: القوة القاهرة والتنازل عن الحقوق وأولوية النسخة العربية — صياغة نموذجية تحتاج مراجعة.]]

## 21. التواصل
{{company_name}}
- الهاتف: {{phone}}
- البريد الإلكتروني: {{email}}
- العنوان: {{address}}
- السجل التجاري: {{commercial_register}} — البطاقة الضريبية: {{tax_registration}}
`.trim();

const TERMS_EN = `
These Terms and Conditions (the "Terms") are an agreement between **{{company_name}}** ("Kayan", "we") and the company, organisation or person that creates an account on the Kayan platform (the "Customer", "you"). By using the platform or completing a purchase you confirm that you have read and accepted these Terms, the Privacy Policy and the Refund & Cancellation Policy.

[[REVIEW: Fill in the operator's full legal name, commercial register, tax registration and address in the "Legal pages" settings, and confirm whether the operator is a company or a sole trader.]]

## 1. Definitions
- **Platform**: the Kayan business-management system provided online as a service (SaaS), including its screens, reports and updates.
- **Account**: a company's account on the Platform together with its users.
- **Owner**: the user who created the Account or holds the "owner" role; responsible for the subscription and payment.
- **Package**: the set of modules and limits (team members and warehouses) shown on the pricing page.
- **Perpetual License** and **Monthly Subscription**: the two payment options described in section 6.
- **Customer Data**: everything you or your team enter into the Platform (customers, suppliers, products, invoices, payments, expenses and so on).

## 2. The service
The Platform provides tools to manage sales, purchases, inventory, treasury, customers, suppliers, sales representatives, commissions and reports, in Arabic and in Egyptian pounds. The modules available depend on the Package. We keep improving the Platform and may add, change or retire features; we will not reduce the modules and limits you paid for except with your consent or as the law permits.

## 3. Account and eligibility
- The user must be an adult authorised to contract on behalf of the company or organisation they represent, and use the Platform for lawful business purposes.
- You are responsible for the accuracy and updating of the information you provide, for the confidentiality of your password and for all activity under your Account.
- We may refuse or suspend an account where we suspect false information or prohibited use.

## 4. Users and roles
An Account has three roles: owner, sales representative and storekeeper, each with different permissions. The Owner is responsible for inviting users, for their permissions, for their compliance with these Terms and for removing access of anyone who leaves the company. We are not a party to the relationship between a company and its staff.

## 5. Packages, limits and modules
A Package defines the available modules and the number of active team members and warehouses. Additions beyond your Package limits are blocked, without deleting any existing data. Changing Package after purchase is not automated at present; it is done by contacting us and as agreed in writing.
[[REVIEW: An upgrade/downgrade and proration policy is not implemented in the system; decide it commercially before promising it.]]

## 6. Two ways to pay
**a) Perpetual License.** You pay the license fee once. It is a right to use the Platform with the chosen Package, not a transfer of ownership of the software or its source code. The Platform is hosted by us, so **hosting and maintenance** are paid monthly and separately (the first payment normally includes the first month of hosting, as shown in the order summary). The license itself does not expire when hosting expires, but **access to the hosted service** stops when the paid period and the grace period end, and returns as soon as a renewal is paid.

**b) Monthly Subscription.** One all-inclusive monthly price covering access, hosting and maintenance. Each paid month extends the service by one month from the end of the current period (or from the payment date if it has already ended).

The prices shown on the pricing page when you buy apply to your order and are stored with it. A later price change does not alter a paid order and does not give rise to any difference to be refunded.
[[REVIEW: A "perpetual license" combined with access stopping when hosting lapses needs legal and commercial review so it cannot be read as breaching the perpetual right to use.]]

## 7. Payment through XPay
- Payments are made through the **XPay** gateway on its own secure payment page. **Your card details never pass through Kayan's servers and we do not store them.**
- We never charge automatically and never renew automatically: each month is a separate payment that the Owner starts personally.
- A Package or renewal is activated only after the **payment is confirmed by the payment gateway** and the amount is verified against the order. Reaching the success page is not enough on its own, and confirmation may take a few moments.
- XPay's terms and your card issuer's terms apply to the payment itself, and we are not responsible for failures outside our control.

## 8. Taxes and invoices
Prices are in Egyptian pounds as shown in the order summary. We issue an invoice or receipt for payments as the applicable laws require. If value-added tax or any other tax applies, it is shown on the invoice according to our tax status.
[[REVIEW: The system does not currently show a separate VAT line. Decide VAT registration (14% on electronic services) and e-invoicing with the Egyptian Tax Authority, and whether displayed prices include tax.]]

## 9. Term, renewal, grace period and suspension
- Access starts when payment is confirmed and lasts until the end of the paid period.
- After the paid period ends a **grace period** applies, whose length is set by the platform (the remaining time is shown in a persistent notice while you use it). During it you keep using the Platform normally, with a renewal reminder.
- When the grace period ends, **access to the Account and its data stops** until a renewal payment is confirmed. A pending, failed or cancelled payment does not restore access.
- We do not delete your data automatically when a subscription ends; see section 10.
- The length of the grace period can be changed by the platform administrator and can be zero.

## 10. Customer Data
- **Your data is yours.** We process it only to provide the service to you, as described in the [Privacy Policy](/privacy).
- You are responsible for the lawfulness of the data you enter (including data about your customers and suppliers) and for obtaining any consents required from them.
- You can export reports and invoices as Excel and PDF from the Platform. You may request a copy of your data, or its deletion, in writing using the contact details below.
[[REVIEW: Define how long data is kept after a subscription ends and when it is deleted, plus the delivery method and the time we commit to for export requests. No automatic deletion policy is implemented today.]]

## 11. Acceptable use
You must not: use the Platform for unlawful purposes or in breach of Egyptian law; try to reach another company's data, exceed your permissions or bypass data isolation; reverse-engineer, copy or resell the Platform; upload malware or overload the service; or share login details with unauthorised people. We may suspend access for a serious breach, notifying you where possible.

## 12. Intellectual property
The Platform, its design, texts, code and the "Kayan" mark belong to us or our licensors. These Terms give you only a right to use the Platform under the chosen Package, which is non-exclusive and may not be assigned or sub-licensed.

## 13. Availability, support and maintenance
We take reasonable care to keep the Platform available and secure, but it may be interrupted for maintenance or for reasons beyond our control (hosting and telecom providers). **We do not commit to a specific uptime percentage** unless agreed in writing. "Maintenance" covers fixing software defects and necessary security updates; it does not cover developing custom features or reports, migrating data from another system, or training your team.

## 14. Limits of liability
- The Platform is a business-management aid; **you remain responsible for reviewing your figures and your accounting and tax decisions**, and it does not replace an accountant or adviser.
- To the extent the law allows, we are not liable for lost profit or indirect damage, and our total liability for any claim is limited to what you actually paid us in the twelve months before the event.
- Nothing in this section excludes liability that cannot lawfully be excluded, including liability for fraud or gross negligence.
[[REVIEW: The 12-month liability cap is a commercial assumption. Under the Egyptian Civil Code an exclusion of liability for fraud or gross negligence is void and courts may amend abusive terms in adhesion contracts (Art. 149). Have a lawyer review the wording.]]

## 15. Cancellation and refunds
These are governed by the [Refund & Cancellation Policy](/refund-policy), which forms part of these Terms. It does not affect any right the law gives you.

## 16. Suspension and termination
- You may stop using the Platform at any time by not renewing; nothing is charged to you automatically.
- We may suspend or terminate an Account for a serious breach of these Terms or unlawful use, notifying you where possible.
- Termination does not affect rights and obligations that arose before it.

## 17. Changes to these Terms
We may amend these Terms. The new version is published on this page with its number and date, and we ask for your acceptance of the current version at each new payment. An amendment does not apply retroactively to an order you have paid.
[[REVIEW: Is publication on the page enough, or must existing customers be notified by email and given a right to object/terminate for a material change?]]

## 18. Electronic acceptance and acceptance record
When you start a payment you confirm, by ticking the box, that you have read these Terms, the Privacy Policy and the Refund & Cancellation Policy. We record with your order **the version numbers you accepted, the date and time of acceptance** and technical data (network address and browser type) as evidence of acceptance.
[[REVIEW: Confirm this electronic evidence is sufficient under the E-Signature Law No. 15 of 2004, and that recording the network address and browser type as evidence is consistent with the Personal Data Protection Law.]]

## 19. Governing law and jurisdiction
These Terms are governed by the laws of the Arab Republic of Egypt, and the courts of **[Cairo]** have jurisdiction over any dispute arising from them, without affecting your right to approach the competent authorities provided by law (including the Consumer Protection Agency where the Consumer Protection Law applies).
[[REVIEW: Choice of court (Cairo?) or arbitration, and whether Consumer Protection Law No. 181 of 2018 applies to business customers.]]

## 20. General
- The Arabic version prevails over the English translation if they differ.
- If a clause is found invalid, the remaining clauses are unaffected.
- A delay in exercising a right is not a waiver of it. We are not liable for delay caused by force majeure.
- These Terms together with the Privacy Policy and the Refund & Cancellation Policy are the entire agreement between us regarding the Platform.
[[REVIEW: Force majeure, non-waiver and Arabic precedence — standard wording that needs review.]]

## 21. Contact
{{company_name}}
- Phone: {{phone}}
- Email: {{email}}
- Address: {{address}}
- Commercial register: {{commercial_register}} — Tax registration: {{tax_registration}}
`.trim();

const PRIVACY_AR = `
توضح هذه السياسة كيف تجمع **{{company_name}}** ("كيان") بياناتك الشخصية وتستخدمها وتحميها عند استخدامك منصة كيان وموقعها. نلتزم بقانون حماية البيانات الشخصية رقم 151 لسنة 2020 ولائحته التنفيذية وبالقوانين المصرية الأخرى ذات الصلة.

[[REVIEW: يجب مراجعة التزامات الجهة بموجب قانون حماية البيانات الشخصية ولائحته التنفيذية (قرار وزير الاتصالات رقم 816 لسنة 2025): التراخيص والتصاريح من مركز حماية البيانات الشخصية، وتعيين مسؤول حماية بيانات، وممثل محلي إن كانت الجهة خارج مصر، ومواعيد الامتثال الانتقالية.]]

## 1. من نحن وما دورنا
- في بيانات **حسابك وفوترتك واستخدامك للمنصة** نحن "المتحكم" في البيانات.
- في **بيانات عملك التي تُدخلها في المنصة** (عملاؤك وموردوك وفواتيرك…) أنت المتحكم ونحن "المعالج" الذي يعالجها نيابةً عنك ووفق تعليماتك لتقديم الخدمة.
[[REVIEW: توصيف الأدوار (متحكم/معالج) وصياغة عقد معالجة البيانات مع العملاء يحتاجان مراجعة قانونية.]]

## 2. البيانات التي نجمعها
- **بيانات الحساب**: الاسم/اسم الشركة ونوع النشاط والبريد الإلكتروني وكلمة المرور (تُحفظ مُجزّأة وليست نصًا مقروءًا) ودور المستخدم.
- **بيانات عملك**: ما تُدخله في المنصة من عملاء وموردين وأصناف وفواتير ومدفوعات ومصروفات وغيرها، وقد تتضمن بيانات أشخاص (أسماء وهواتف وعناوين).
- **بيانات الطلب والدفع**: الباقة وخيار الدفع والمبلغ وحالة الدفع ومعرّفات الطلب والدفع. **لا نستلم رقم بطاقتك ولا رمز التحقق**؛ تُدخلهما في صفحة XPay.
- **سجل الموافقة**: أرقام نسخ الشروط والسياسات التي وافقت عليها وتاريخ الموافقة وعنوان الشبكة ونوع المتصفح.
- **بيانات تقنية**: سجلات التشغيل والأمان ومعلومات الجهاز والمتصفح اللازمة لتأمين الخدمة وتشخيص الأعطال.
- **مراسلاتك معنا** وبياناتك عند التواصل مع الدعم.

## 3. لماذا نعالجها وعلى أي أساس
- **تنفيذ العقد**: إنشاء حسابك وتقديم الخدمة ومعالجة الدفع والتجديد وإصدار الفواتير.
- **الالتزام القانوني**: حفظ السجلات والفواتير والسجلات التقنية كما تفرض القوانين المصرية.
- **الموافقة**: لما يتطلب موافقتك الصريحة، ويمكنك سحبها وفق البند 8.
- **المصلحة المشروعة**: تأمين المنصة ومنع الاحتيال وتحسين الأداء، دون الإضرار بحقوقك.
لا نبيع بياناتك الشخصية ولا نستخدمها للإعلانات.
[[REVIEW: تحقق من الأسس القانونية المناسبة لكل غرض وفق المادة 6 من القانون وإرشادات مركز حماية البيانات بشأن الموافقة.]]

## 4. مع من نشارك البيانات
- **XPay** لمعالجة المدفوعات (تتلقى بيانات الدفع التي تدخلها مباشرة في صفحتها).
- **مزوّدو البنية السحابية**: قاعدة البيانات والمصادقة (Supabase) واستضافة التطبيق (Vercel)، ومرسِل رسائل البريد الإلكتروني الخاصة بتأكيد الحساب واستعادة كلمة المرور.
- **الجهات الرسمية** عند وجود التزام قانوني أو أمر قضائي.
- أعضاء فريقك حسب صلاحياتهم داخل الحساب. تُعزل بيانات كل شركة عن الشركات الأخرى.
نُلزم هؤلاء المزوّدين بحماية البيانات بالقدر المناسب، ولا نشارك بياناتك لأغراض تسويقية للغير.
[[REVIEW: أكمل القائمة الفعلية للمعالجين الفرعيين ومواقع خوادمهم ومدى وجود اتفاقيات معالجة معهم.]]

## 5. نقل البيانات خارج مصر
قد تُخزَّن البيانات وتُعالج لدى مزوّدين تقع خوادمهم خارج مصر. نقل البيانات خارج مصر يخضع لضوابط القانون ولائحته، ونتخذ ما يلزم لذلك.
[[REVIEW: موقع خوادم قاعدة البيانات والاستضافة غير محدد في هذا المشروع. يتطلب القانون ولائحته ضوابط خاصة ومنها موافقة المركز على نقل البيانات خارج مصر في الحالات المحددة. حدّد المناطق الفعلية وتحقق من المتطلبات قبل النشر.]]

## 6. مدة الاحتفاظ
- بيانات الحساب وعملك: طوال مدة الاشتراك، وبعد انتهائه نتصرف فيها وفق البند 10 من الشروط وطلبك.
- سجلات الدفع والفواتير: للمدة التي تفرضها القوانين الضريبية والمحاسبية.
- السجلات التقنية: للمدة التي يفرضها القانون على مقدمي الخدمات (180 يومًا وفق قانون مكافحة جرائم تقنية المعلومات رقم 175 لسنة 2018) أو لمدة أقصر إن لم يوجب القانون أكثر.
- سجل الموافقة: ما دام ذلك لازمًا لإثبات الاتفاق والدفاع عن حقوقنا.
[[REVIEW: تحديد مدد الاحتفاظ النهائية (الفواتير والسجلات الضريبية عادةً 5 سنوات)، وعدم وجود حذف تلقائي مطبّق في النظام اليوم.]]

## 7. كيف نحمي بياناتك
نطبّق إجراءات تقنية وتنظيمية مناسبة: عزل بيانات كل شركة على مستوى قاعدة البيانات، وتشفير الاتصال، وتجزئة كلمات المرور، وتقييد الصلاحيات حسب الدور، وسجلات للعمليات الحساسة. لا يوجد نظام آمن تمامًا، ولذلك نوصي بكلمة مرور قوية وعدم مشاركتها.

## 8. حقوقك
وفق القانون يحق لك: العلم بالبيانات التي نحتفظ بها عنك والاطلاع عليها والحصول عليها؛ تصحيحها أو تعديلها؛ تقييد معالجتها أو الاعتراض عليها؛ حذفها حيث لا يوجد التزام قانوني أو غرض مشروع للاحتفاظ بها؛ وسحب موافقتك في أي وقت دون أثر على ما سبق. لممارسة حقوقك راسلنا على بيانات التواصل أدناه، ونرد خلال المدة التي يحددها القانون.
[[REVIEW: آلية استقبال طلبات أصحاب البيانات والمدة الفعلية للرد وفق اللائحة التنفيذية.]]

## 9. ملفات تعريف الارتباط
نستخدم ملفات ارتباط ضرورية فقط لتسجيل دخولك وحفظ جلستك وأمان الموقع. **لا نستخدم ملفات تتبّع إعلانية أو تحليلات من أطراف ثالثة** حاليًا. إن أضفنا ذلك مستقبلًا فسنحدّث هذه السياسة ونطلب موافقتك عند اللزوم.

## 10. الأطفال
المنصة موجّهة للأعمال ولا تستهدف من هم دون 18 عامًا، ولا نجمع عمدًا بيانات الأطفال.

## 11. الإبلاغ عن الاختراقات
إذا وقع اختراق لبيانات شخصية يعرّضك لخطر، نخطر الجهات والأشخاص المعنيين وفق ما يوجبه القانون ولائحته التنفيذية.
[[REVIEW: إجراءات الإبلاغ عن الاختراق ومواعيده وفق اللائحة التنفيذية، وتحديد المسؤول عنها داخليًا.]]

## 12. تعديل هذه السياسة
قد نحدّث هذه السياسة، وننشر النسخة الجديدة برقمها وتاريخها هنا، ونطلب موافقتك على النسخة الحالية عند كل عملية دفع جديدة.

## 13. التواصل والشكاوى
لأي استفسار أو لممارسة حقوقك:
{{company_name}}
- الهاتف: {{phone}}
- البريد الإلكتروني: {{email}}
- العنوان: {{address}}
يحق لك أيضًا تقديم شكوى إلى **مركز حماية البيانات الشخصية** في مصر.
`.trim();

const PRIVACY_EN = `
This policy explains how **{{company_name}}** ("Kayan") collects, uses and protects your personal data when you use the Kayan platform and website. We comply with the Personal Data Protection Law No. 151 of 2020 and its executive regulations and with other relevant Egyptian laws.

[[REVIEW: Review the operator's obligations under the Personal Data Protection Law and its executive regulations (Minister of Communications Decision No. 816 of 2025): licences/permits from the Personal Data Protection Centre, appointing a data protection officer, a local representative if the operator is outside Egypt, and the transitional compliance deadlines.]]

## 1. Who we are and our role
- For your **account, billing and use of the Platform** we are the "controller".
- For **your business data that you enter into the Platform** (your customers, suppliers, invoices…) you are the controller and we are the "processor", processing it on your behalf and on your instructions to provide the service.
[[REVIEW: The controller/processor characterisation and the data processing agreement with customers need legal review.]]

## 2. Data we collect
- **Account data**: name/company name, business type, email, password (stored hashed, never in readable form) and the user's role.
- **Your business data**: what you enter into the Platform — customers, suppliers, products, invoices, payments, expenses and so on — which may include data about people (names, phone numbers, addresses).
- **Order and payment data**: the Package, payment option, amount, payment status and order/payment identifiers. **We do not receive your card number or security code**; you enter them on the XPay page.
- **Acceptance record**: the version numbers of the terms and policies you accepted, the date and time, network address and browser type.
- **Technical data**: operating and security logs and the device/browser information needed to secure the service and diagnose faults.
- **Your communications with us** and the data you provide when contacting support.

## 3. Why we process it and on what basis
- **Performance of the contract**: creating your account, providing the service, processing payment and renewal, issuing invoices.
- **Legal obligation**: keeping records, invoices and technical logs as Egyptian laws require.
- **Consent**: where your explicit consent is required; you can withdraw it as set out in section 8.
- **Legitimate interest**: securing the Platform, preventing fraud and improving performance, without harming your rights.
We do not sell your personal data and do not use it for advertising.
[[REVIEW: Check the appropriate legal basis for each purpose under Article 6 of the Law and the Centre's guidance on consent.]]

## 4. Who we share data with
- **XPay** to process payments (it receives the payment details you enter directly on its page).
- **Cloud infrastructure providers**: the database and authentication provider (Supabase) and the application host (Vercel), and the sender of account-confirmation and password-reset emails.
- **Official authorities** where there is a legal obligation or a court order.
- Your team members, according to their permissions inside the Account. Each company's data is isolated from other companies.
We require these providers to protect data appropriately, and we do not share your data with third parties for their marketing.
[[REVIEW: Complete the actual list of sub-processors, the location of their servers and whether processing agreements are in place.]]

## 5. Transfers outside Egypt
Data may be stored and processed by providers whose servers are outside Egypt. Transfers outside Egypt are subject to the Law and its regulations, and we take the steps they require.
[[REVIEW: The location of the database and hosting servers is not specified in this project. The Law and its regulations impose specific controls, including the Centre's approval for transfers outside Egypt in defined cases. Identify the actual regions and verify the requirements before launch.]]

## 6. How long we keep data
- Account and business data: for the duration of the subscription, and afterwards handled under section 10 of the Terms and your request.
- Payment records and invoices: for the period tax and accounting laws require.
- Technical logs: for the period the law requires of service providers (180 days under the Anti-Cyber and Information Technology Crimes Law No. 175 of 2018) or shorter where the law requires no more.
- Acceptance record: as long as needed to prove the agreement and defend our rights.
[[REVIEW: Set the final retention periods (invoices and tax records are typically 5 years). No automatic deletion is implemented in the system today.]]

## 7. How we protect your data
We apply appropriate technical and organisational measures: isolation of each company's data at database level, encrypted connections, hashed passwords, role-based permissions and logs for sensitive operations. No system is perfectly secure, so we recommend a strong password that you do not share.

## 8. Your rights
Under the law you may: be informed of and access the data we hold about you and obtain it; have it corrected or amended; restrict or object to its processing; have it deleted where there is no legal obligation or legitimate purpose to keep it; and withdraw your consent at any time without affecting earlier processing. To exercise your rights write to the contact details below; we respond within the period the law sets.
[[REVIEW: The mechanism for receiving data-subject requests and the actual response time under the executive regulations.]]

## 9. Cookies
We use only the essential cookies needed to sign you in, keep your session and secure the site. **We do not currently use advertising trackers or third-party analytics.** If we add them in future we will update this policy and ask for your consent where required.

## 10. Children
The Platform is for businesses and is not aimed at anyone under 18; we do not knowingly collect children's data.

## 11. Personal data breaches
If a breach of personal data creates a risk for you, we notify the relevant authorities and people as the law and its executive regulations require.
[[REVIEW: Breach-notification procedure and deadlines under the executive regulations, and who is responsible internally.]]

## 12. Changes to this policy
We may update this policy. The new version is published here with its number and date, and we ask for your acceptance of the current version at each new payment.

## 13. Contact and complaints
For any question or to exercise your rights:
{{company_name}}
- Phone: {{phone}}
- Email: {{email}}
- Address: {{address}}
You may also complain to the **Personal Data Protection Centre** in Egypt.
`.trim();

const REFUND_AR = `
توضح هذه السياسة كيف يمكنك إلغاء اشتراكك أو التوقف عن التجديد وطلب استرداد مبلغ دفعته إلى **{{company_name}}** ("كيان"). تُقرأ مع [الشروط والأحكام](/terms).

[[REVIEW: مدد الاسترداد والاستثناءات أدناه قرارات تجارية افتراضية وضعناها كمسودة. لا يلزم القانون بها كلها، ويجب أن تقرّرها أنت وتراجعها مع محامٍ، وتتأكد من إمكانية تنفيذها فعليًا (الاسترداد يتم يدويًا من لوحة XPay ولا يعكسه النظام تلقائيًا).]]

## 1. المبدأ
دفعاتك تخص خدمة رقمية تُفعَّل فور تأكيد الدفع. نلتزم برد المبالغ في الحالات الموضحة أدناه، ولا يخلّ ذلك بأي حق مقرر لك بموجب القانون المصري، ومنه قانون حماية المستهلك رقم 181 لسنة 2018 متى انطبق عليك.
[[REVIEW: هل ينطبق قانون حماية المستهلك (ومنه حق الرجوع خلال 14 يومًا للسلع وأحكام البيع عن بعد) على عملاء من الشركات واشتراكات البرمجيات المقدّمة كخدمة؟ هذا يحدد الحد الأدنى الإلزامي للاسترداد.]]

## 2. الإلغاء ووقف التجديد
- **لا يوجد تجديد تلقائي ولا خصم تلقائي.** يمكنك التوقف في أي وقت بعدم دفع الشهر التالي، ولا حاجة إلى إجراء إلغاء.
- يبقى الوصول متاحًا حتى نهاية الفترة المدفوعة وفترة السماح التي تحددها المنصة.
- طلب إلغاء الحساب وحذف البيانات يتم بطلب كتابي (انظر البند 8).

## 3. الاشتراك الشهري
الشهر المدفوع غير قابل للاسترداد بعد تفعيل الوصول، **عدا** الحالات المذكورة في البند 6 وما يقرره القانون. (وبالنسبة لأول شراء انظر البند 4.)

## 4. أول شراء: مهلة إلغاء 14 يومًا
يمكنك خلال **14 يومًا تقويميًا** من تاريخ تفعيل أول شراء لحسابك طلب إلغائه واسترداد ما دفعته، على أن:
- يُخصم قيمة **الاستضافة والصيانة** عن الفترة التي استخدمتها إن كان الشراء رخصة دائمة؛
- ولا يُقبل الطلب إذا اتُّخذ منه استخدام جسيم يخالف الشروط.
بعد انتهاء المهلة لا تُستردّ مبالغ الرخصة إلا في الحالات المذكورة في البند 6 أو بحكم القانون.
[[REVIEW: مدة 14 يومًا وطريقة خصم الاستضافة افتراضان تجاريان استلهمناهما من مدة الرجوع في قانون حماية المستهلك؛ قرّر ما تلتزم به فعلًا.]]

## 5. الاستضافة والصيانة
الاستضافة والصيانة الشهرية تُدفع عن شهر مقدّم ولا تُستردّ بعد انقضاء الشهر أو بعد استخدام الخدمة فيه، عدا الحالات المذكورة في البند 6.

## 6. حالات الاسترداد الكامل
نردّ المبلغ كاملًا في الحالات الآتية:
- **دفع مكرر** لنفس الطلب أو الشهر؛
- **خصم دون تفعيل**: تم الخصم من بطاقتك ولم نتمكن من تفعيل الباقة أو التجديد لسبب يرجع إلينا أو إلى النظام، ولم يمكن تصحيح ذلك خلال مدة معقولة؛
- **مبلغ غير مطابق** لما ظهر في ملخص الطلب؛
- أي حالة يوجب فيها القانون الاسترداد.

## 7. ما لا يُستردّ
- رسوم أو مصاريف فرضها مُصدر بطاقتك أو مزوّد الدفع خارج سيطرتنا، ما لم يوجب القانون غير ذلك؛
- الخدمات المخصّصة التي طُلبت منا خارج الباقة (تطوير مخصص، ترحيل بيانات، تدريب) بعد تنفيذها؛
- الاستخدام المخالف للشروط الذي أدى إلى تعليق الحساب.

## 8. كيف تقدّم طلبًا
راسلنا من البريد الإلكتروني المسجل في حسابك على البيانات الموضحة في البند 11، مع ذكر **رقم الطلب** (يظهر في صفحة تأكيد الدفع وفي سجل المدفوعات) وسبب الطلب. قد نطلب معلومات إضافية للتحقق من هويتك وملكيتك للحساب.

## 9. طريقة الاسترداد ومدته
- يتم الرد على طلبك خلال **[5] أيام عمل**.
- يُرَدّ المبلغ بنفس وسيلة الدفع المستخدمة عبر XPay. وتختلف مدة ظهور المبلغ في حسابك حسب بنك مُصدر البطاقة ومزوّد الدفع، ولا نتحكم فيها.
- عند الاسترداد قد نوقف الاشتراك المرتبط به من تاريخه.
[[REVIEW: مدة الرد (5 أيام عمل) التزام تجاري يجب أن تتأكد من قدرتك على الوفاء به.]]

## 10. الدفعات المعلّقة أو الفاشلة
الدفع الفاشل أو الملغي لا يُفعّل الباقة ولا يُعاد به الوصول. إذا خُصم مبلغ ولم يصلنا تأكيد من بوابة الدفع فتتم المطابقة تلقائيًا فور وصوله؛ وإن لم يحدث فتواصل معنا لنحقق ونردّ ما يجب رده.

## 11. التواصل
{{company_name}}
- الهاتف: {{phone}}
- البريد الإلكتروني: {{email}}
- العنوان: {{address}}
إن رأيت أن حقوقك لم تُراعَ فيحق لك اللجوء إلى الجهات المختصة، ومنها جهاز حماية المستهلك أو القضاء.
`.trim();

const REFUND_EN = `
This policy explains how you can cancel your subscription or stop renewing, and how to ask for a refund of an amount you paid to **{{company_name}}** ("Kayan"). Read it with the [Terms and Conditions](/terms).

[[REVIEW: The refund periods and exceptions below are default commercial decisions we drafted. The law does not require all of them; you must decide them, have a lawyer review them, and make sure you can actually deliver them (refunds are issued manually from the XPay dashboard; the system does not reverse them automatically).]]

## 1. Principle
Your payments are for a digital service that is activated as soon as payment is confirmed. We refund in the cases set out below, and nothing here affects any right the Egyptian law gives you, including Consumer Protection Law No. 181 of 2018 where it applies to you.
[[REVIEW: Does the Consumer Protection Law (including the 14-day right of return for goods and the distance-selling rules) apply to business customers and to software-as-a-service subscriptions? This sets the mandatory minimum for refunds.]]

## 2. Cancelling and stopping renewal
- **There is no automatic renewal and no automatic charge.** You can stop at any time by not paying the next month; no cancellation step is needed.
- Access remains available until the end of the paid period and the grace period set by the platform.
- A request to close the account and delete the data is made in writing (see section 8).

## 3. Monthly subscription
A paid month is not refundable once access is activated, **except** in the cases in section 6 and as the law requires. (For a first purchase see section 4.)

## 4. First purchase: 14-day cancellation window
Within **14 calendar days** of the activation of your account's first purchase you may ask to cancel it and receive back what you paid, provided that:
- for a perpetual license, the value of the **hosting and maintenance** for the period you used is deducted;
- and the request is not accepted where there has been serious use in breach of the Terms.
After the window, license amounts are refunded only in the cases in section 6 or as the law requires.
[[REVIEW: The 14-day period and the hosting deduction are commercial assumptions inspired by the return period in the Consumer Protection Law; decide what you will really commit to.]]

## 5. Hosting and maintenance
Monthly hosting and maintenance is paid for a month in advance and is not refunded once the month has passed or the service has been used in it, except in the cases in section 6.

## 6. Full refunds
We refund the full amount in these cases:
- a **duplicate payment** for the same order or month;
- **charged but not activated**: your card was charged and we could not activate the Package or renewal for a reason attributable to us or the system, and it could not be corrected within a reasonable time;
- an **amount that does not match** the order summary;
- any case in which the law requires a refund.

## 7. What is not refunded
- Fees or charges imposed by your card issuer or the payment provider outside our control, unless the law requires otherwise;
- custom services requested from us outside the Package (custom development, data migration, training) once performed;
- use in breach of the Terms that led to suspension of the account.

## 8. How to request
Write to us from the email registered on your account at the details in section 11, quoting the **order number** (shown on the payment confirmation page and in the payment history) and the reason. We may ask for further information to verify your identity and ownership of the account.

## 9. Refund method and timing
- We answer your request within **[5] business days**.
- The refund goes back to the payment method used, through XPay. How long it takes to appear in your account depends on your card issuer and the payment provider and is outside our control.
- On a refund we may suspend the related subscription from that date.
[[REVIEW: The 5-business-day response time is a commercial commitment you must be able to meet.]]

## 10. Pending or failed payments
A failed or cancelled payment does not activate a Package and does not restore access. If an amount was charged but confirmation from the payment gateway has not reached us, it is matched automatically as soon as it arrives; if that does not happen, contact us and we will investigate and refund what must be refunded.

## 11. Contact
{{company_name}}
- Phone: {{phone}}
- Email: {{email}}
- Address: {{address}}
If you believe your rights were not respected you may go to the competent authorities, including the Consumer Protection Agency or the courts.
`.trim();

export const LEGAL_DEFAULTS: Record<LegalKey, LegalDefault> = {
  terms: { titleAr: "الشروط والأحكام", bodyAr: TERMS_AR, titleEn: "Terms & Conditions", bodyEn: TERMS_EN },
  privacy: { titleAr: "سياسة الخصوصية", bodyAr: PRIVACY_AR, titleEn: "Privacy Policy", bodyEn: PRIVACY_EN },
  refund: { titleAr: "سياسة الإلغاء والاسترداد", bodyAr: REFUND_AR, titleEn: "Refund & Cancellation Policy", bodyEn: REFUND_EN },
};

export const LEGAL_KEYS: LegalKey[] = ["terms", "privacy", "refund"];

/** Public URL of each document. */
export const LEGAL_PATH: Record<LegalKey, string> = { terms: "/terms", privacy: "/privacy", refund: "/refund-policy" };
