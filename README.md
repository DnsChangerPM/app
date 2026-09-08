# 🛡️ DNS Changer — اندروید + پنل ادمین کلودفلر

یک برنامه‌ی **تغییر DNS برای اندروید** با فلاتر که دقیقاً مثل «DNS Changer» های معروف
گوگل‌پلی کار می‌کند، ولی کامل‌تر:

- ✅ بخش **رایگان** با DNS های عمومی (Cloudflare ،Google ،Quad9 ،Shecan ،Electro و…)
- ✅ بخش **اشتراکی (خصوصی)** با **لایسنس** — DNS اشتراک قفل است و فقط دکمه‌ی «فعال‌سازی» می‌آید
- ✅ **پنل ادمین رایگان روی Cloudflare Workers + KV** (بدون هیچ هزینه‌ای)
- ✅ ساخت لایسنس با **محدودیت تعداد دستگاه**، مدت‌زمان، و DNS های دلخواه
- ✅ مشاهده‌ی **لیست دستگاه‌های هر لایسنس** (نام، آی‌دی، آخرین ورود، IP) و حذف دستگاه
- ✅ **به‌روزرسانی اجباری**: وقتی نسخه‌ی جدید منتشر می‌کنید، نسخه‌ی قبلی از کار می‌افتد و
      کاربر هشدار می‌گیرد + دکمه‌ی **دانلود مستقیم APK** (بدون رفتن به گیت‌هاب)
- ✅ **انتشار خودکار APK** در بخش Releases گیت‌هاب با GitHub Actions (ازت نسخه می‌پرسد)
- ✅ امکان **تمرکز روی یک برنامه‌ی خاص** (مثل `com.tencent.ig`)

---

## 🗂 ساختار پروژه

```
app/
├── lib/                      ← کد فلاتر (UI + سرویس‌ها)
│   ├── main.dart
│   ├── models/               ← مدل‌های DNS، لایسنس، ریلیز
│   ├── screens/              ← صفحه اصلی، لایسنس، تنظیمات
│   ├── services/             ← VPN، لایسنس، آپدیت، کاتالوگ DNS
│   └── widgets/              ← کارت سرور، صفحه‌ی آپدیت اجباری
├── android/                  ← پروژه‌ی اندروید + VpnService بومی (کاتلین)
│   └── app/src/main/kotlin/com/dnschanger/app/
│       ├── DnsVpnService.kt  ← تونل DNS (UDP/TCP)
│       ├── DnsResolver.kt    ← ارسال کوئری به DNS بالادستی
│       ├── TcpProxy.kt       ← پشتیبانی DNS-over-TCP
│       └── PacketUtils.kt    ← ساخت/پارس بسته‌های IP
├── cloudflare/               ← Worker پنل ادمین (رایگان)
│   ├── src/index.js          ← API لایسنس + ریلیز + پنل HTML
│   └── wrangler.toml         ← تنظیمات deploy (خودت ID ها را بگذار)
├── .github/workflows/
│   ├── release.yml           ← build + انتشار APK در Releases
│   └── ci.yml                ← build تستی روی هر push
└── scripts/gen_keystore.sh   ← ساخت کلید امضا برای انتشار پایدار
```

---

## ۱) اجرا و build برنامه

```bash
flutter pub get
flutter run              # اجرا روی دستگاه
flutter build apk --release
```

> برای امضای ریلیزِ پایدار (تا کاربران بتوانند نسخه‌ها را روی هم آپدیت کنند):
> ```bash
> bash scripts/gen_keystore.sh
> ```
> خروجی آن را به‌عنوان Secret های گیت‌هاب اضافه کنید (پایین‌تر توضیح داده شده).

---

## ۲) انتشار APK با GitHub Actions

1. به تب **Actions** ریپو برو → **Build & Release APK** → **Run workflow**.
2. در فیلد **version** نسخه را بزن (مثلاً `1.2.0`). نسخه باید به شکل `X.Y.Z` باشد.
3. (اختیاری) توضیحات ریلیز را بنویس.
4. Run بزن. بعد از پایان، در بخش **Releases** یک APK آماده‌ی دانلود هست.

### امضای ثابت (برای آپدیت بدون خطا) — مهم!
اگر Secret های امضا را نگذاری، APK با کلید debug امضا می‌شود و کاربران **نمی‌توانند**
نسخه‌ی جدید را روی نسخه‌ی قبلی نصب کنند. پس:

1. `bash scripts/gen_keystore.sh` را اجرا کن.
2. در ریپو: **Settings → Secrets and variables → Actions** این چهار Secret را اضافه کن:
   - `KEYSTORE_BASE64`
   - `KEYSTORE_PASSWORD`
   - `KEY_ALIAS`
   - `KEY_PASSWORD`

---

## ۳) پنل ادمین روی Cloudflare (رایگان)

```bash
cd cloudflare
npm install
npx wrangler login

# سه KV namespace بساز (ID ها را کپی کن):
npx wrangler kv namespace create LICENSES
npx wrangler kv namespace create DEVICES
npx wrangler kv namespace create CONFIG
```

ID ها را در `cloudflare/wrangler.toml` بگذار، بعد:

```bash
npx wrangler secret put ADMIN_KEY    # کلید ورود به پنل (اختیاری ولی پیشنهادی)
npx wrangler deploy
```

آدرس پنل: `https://dns-changer-admin.xxx.workers.dev/admin`

> راهنمای کامل‌تر: [`cloudflare/README.md`](cloudflare/README.md)

### لینک کردن برنامه به پنل
آدرس Worker را در برنامه بده (پیش‌فرض داخل کد هست):
- داخل برنامه: **Settings → Cloudflare API → Worker URL**
- یا موقع build:
  ```bash
  flutter build apk --dart-define=API_BASE_URL=https://YOUR.workers.dev
  ```

---

## ۴) ساخت لایسنس و محدودیت دستگاه

در پنل ادمین → تب **Licenses**:

1. نام پلن، **حد دستگاه** (مثلاً ۳)، مدت (روز یا مادام‌العمر) و **DNS های خصوصی** را وارد کن (مثلاً `1.1.1.1, 1.0.0.1`).
2. **Generate license key** را بزن و کلید را برای کاربر بفرست.
3. کاربر در برنامه کلید را می‌زند → لایسنس فعال می‌شود. DNS اشتراک **قفل** است و فقط
   گزینه‌ی «فعال» نشان داده می‌شود (آدرس‌ها در پاسخ API به‌صورت base64 می‌آیند و در UI نمایش داده نمی‌شوند).
4. با زدن دکمه‌ی **Devices** روی هر لایسنس، دستگاه‌های متصل (نام، آی‌دی، زمان، IP) را می‌بینی و می‌توانی هر دستگاه را حذف کنی.

---

## ۵) از کار انداختن نسخه‌ی قبلی هنگام انتشار نسخه‌ی جدید

دو راه:

- **اتوماتیک:** این Secret ها را در گیت‌هاب بگذار تا هر بار که workflow ریلیز ران می‌شود،
  نسخه‌ی جدید به‌عنوان `min_version` در پنل ثبت شود و نسخه‌ی قبلی از کار بیفتد:
  - `CLOUDFLARE_WORKER_URL` (مثلاً `https://dns-changer-admin.xxx.workers.dev`)
  - `ADMIN_KEY`

- **دستی:** در پنل ادمین → **Settings** → فیلد **Minimum required version** نسخه‌ی جدید را بگذار،
  یا در **Killed versions** نسخه‌های قدیمی را لیست کن.

وقتی برنامه‌ای روی نسخه‌ی kill شده باشد، یک **صفحه‌ی هشدار تمام‌صفحه** می‌آید:
«نسخه‌ی جدید لازم است» + دکمه‌ی **دانلود** که APK را **مستقیم** دانلود می‌کند (کاربر به گیت‌هاب نمی‌رود).

---

## ⚙️ نکات فنی

- تونل DNS با `VpnService` اندروید (بدون نیاز به روت) پیاده شده.
- فقط ترافیک DNS (پورت ۵۳) از تونل عبور می‌کند؛ بقیه‌ی ترافیک (مثل سرورهای بازی) مستقیم می‌رود،
  پس بازی مثل `com.tencent.ig` بدون اختلال با DNS انتخابی کار می‌کند.
- برای **تمرکز روی یک برنامه‌ی خاص**: تنظیمات → «Focus on a specific app» → نام پکیج را بده
  (پیش‌فرض `com.tencent.ig`). با این گزینه فقط DNS همان برنامه از تونل عبور می‌کند.
- اتصال به Worker به‌صورت `https` است؛ اپ در حالت آفلاین از اطلاعات کش‌شده استفاده می‌کند.

---

## ⚠️ سلب مسئولیت

این پروژه صرفاً جهت اهداف قانونی و استفاده‌ی شخصی ارائه شده است. استفاده‌ی نادرست بر عهده‌ی کاربر است.
