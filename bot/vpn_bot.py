"""
🌈 HAPPVIP BOT with referral system
"""
import asyncio, logging, aiohttp, sqlite3, json
from datetime import datetime, timedelta
from aiogram import Bot, Dispatcher, types, F
from aiogram.filters import CommandStart, Command
from aiogram.types import InlineKeyboardMarkup, InlineKeyboardButton, LabeledPrice, PreCheckoutQuery, Message
from aiogram.fsm.storage.memory import MemoryStorage
BOT_TOKEN = "8719621968:AAFWt_3QHq7f-5FRSG2MZlpt0s7EBdCgCzA"
PANEL_URL = "https://panel.alexanderoff.ru:8444"
PANEL_API_TOKEN = "5c58fb006cee1476fa7e4d27d97c79e8c177bf271fe89665da2a4016d07b1eff"
ADMIN_IDS = [669805176]
SUPPORT = "https://t.me/vpnruss2"
BOT_USERNAME = "HAPPVIPbot"
DB_PATH = "/opt/vpn_panel/bot/referrals.db"
HEADERS = {"Authorization": f"Bearer {PANEL_API_TOKEN}", "Content-Type": "application/json"}
D  = "══════════════════"
D2 = "──────────────────"
PLANS = {
    "trial": {"name": "🎁 Бесплатный тест", "traffic_bytes": 100*1024*1024, "days": 0, "stars": 0},
    "month": {"name": "🚀 1 месяц", "traffic_bytes": 200*1024*1024*1024, "days": 30, "stars": 250},
}
REFERRAL_DAYS_PER_PURCHASE = 7
bot = Bot(token=BOT_TOKEN)
dp = Dispatcher(storage=MemoryStorage())
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)
def db_init():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("""CREATE TABLE IF NOT EXISTS referrals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        referrer_id INTEGER NOT NULL,
        referred_id INTEGER NOT NULL UNIQUE,
        created_at TEXT DEFAULT (datetime('now'))
    )""")
    c.execute("""CREATE TABLE IF NOT EXISTS ref_purchases (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        referrer_id INTEGER NOT NULL,
        referred_id INTEGER NOT NULL,
        bonus_days INTEGER NOT NULL,
        created_at TEXT DEFAULT (datetime('now'))
    )""")
    conn.commit()
    conn.close()
def db_save_referral(referrer_id, referred_id):
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("INSERT OR IGNORE INTO referrals (referrer_id, referred_id) VALUES (?,?)", (referrer_id, referred_id))
        conn.commit(); conn.close()
    except Exception as e:
        logger.error(f"db_save_referral: {e}")
def db_get_referrer(referred_id):
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("SELECT referrer_id FROM referrals WHERE referred_id=?", (referred_id,))
        row = c.fetchone(); conn.close()
        return row[0] if row else None
    except: return None
def db_count_purchases(referrer_id, referred_id):
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("SELECT COUNT(*) FROM ref_purchases WHERE referrer_id=? AND referred_id=?", (referrer_id, referred_id))
        row = c.fetchone(); conn.close()
        return row[0] if row else 0
    except: return 0
def db_save_purchase(referrer_id, referred_id, bonus_days):
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("INSERT INTO ref_purchases (referrer_id, referred_id, bonus_days) VALUES (?,?,?)", (referrer_id, referred_id, bonus_days))
        conn.commit(); conn.close()
    except Exception as e:
        logger.error(f"db_save_purchase: {e}")
def db_get_stats(referrer_id):
    try:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("SELECT COUNT(*) FROM referrals WHERE referrer_id=?", (referrer_id,))
        total_refs = c.fetchone()[0]
        c.execute("SELECT COUNT(DISTINCT referred_id), SUM(bonus_days) FROM ref_purchases WHERE referrer_id=?", (referrer_id,))
        row = c.fetchone()
        conn.close()
        return total_refs, row[0] or 0, row[1] or 0
    except: return 0, 0, 0
async def api_get(path):
    try:
        async with aiohttp.ClientSession() as s:
            async with s.get(f"{PANEL_URL}{path}", headers=HEADERS, ssl=False) as r:
                return await r.json()
    except Exception as e:
        logger.error(f"API GET {path}: {e}"); return None
async def api_post(path, data):
    try:
        async with aiohttp.ClientSession() as s:
            async with s.post(f"{PANEL_URL}{path}", json=data, headers=HEADERS, ssl=False) as r:
                return await r.json()
    except Exception as e:
        logger.error(f"API POST {path}: {e}"); return None
async def api_put(path, data):
    try:
        async with aiohttp.ClientSession() as s:
            async with s.put(f"{PANEL_URL}{path}", json=data, headers=HEADERS, ssl=False) as r:
                return await r.json()
    except Exception as e:
        logger.error(f"API PUT {path}: {e}"); return None
async def get_user_by_tg(tg_id):
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(
                f"{PANEL_URL}/bot/users/{tg_id}",
                headers={"x-bot-token": "bot_e30bbaf2d4e2a9ea85e718aaa340652a"},
                ssl=False
            ) as r:
                u = await r.json()
                if u.get("success"):
                    u["_keys"] = u.get("keys", {})
                    return u
        return None
    except Exception as e:
        logger.error(f"get_user_by_tg: {e}"); return None
async def create_panel_user(tg_id, plan_key):
    plan = PLANS[plan_key]
    expire_at = int((datetime.now()+timedelta(days=plan["days"])).timestamp()) if plan["days"] > 0 else 0
    data = {"username": f"tg_{tg_id}", "telegram_id": str(tg_id),
            "data_limit_mb": plan["traffic_bytes"] / (1024*1024), "expire_at": expire_at}
    async with aiohttp.ClientSession() as session:
        async with session.post(
            f"{PANEL_URL}/bot/users/create",
            json=data,
            headers={"x-bot-token": "bot_e30bbaf2d4e2a9ea85e718aaa340652a"},
            ssl=False
        ) as r:
            result = await r.json()
            if result.get("success"):
                # Получаем полные данные через GET
                async with session.get(
                    f"{PANEL_URL}/bot/users/{tg_id}",
                    headers={"x-bot-token": "bot_e30bbaf2d4e2a9ea85e718aaa340652a"},
                    ssl=False
                ) as r2:
                    user = await r2.json()
                user["_keys"] = result.get("keys", {})
                return user
            return None
async def extend_panel_user(tg_id, user_id, plan_key):
    plan = PLANS[plan_key]
    data = {"data_limit_mb": plan["traffic_bytes"] / (1024*1024), "status": "active", "expire_days": plan["days"]}
    await api_put(f"/api/users/{user_id}", data)
    return await get_user_by_tg(tg_id)
async def add_bonus_days(tg_id, days):
    user = await get_user_by_tg(tg_id)
    if not user: return False
    current_expire = user.get("expire_at", 0) or 0
    if current_expire > datetime.now().timestamp():
        new_expire = int(current_expire + days*86400)
    else:
        new_expire = int(datetime.now().timestamp() + days*86400)
    result = await api_put(f"/api/users/{user.get('user_id') or user.get('id')}", {"expire_at": new_expire, "status": "active"})
    return result is not None
def parse_user_info(user):
    data_used = user.get("data_used", 0) or 0
    data_limit = user.get("data_limit", 0) or 0
    used_str = f"{round(data_used/(1024**3),2)} ГБ" if data_used >= 1024**3 else f"{round(data_used/(1024*1024),1)} МБ"
    limit_str = f"{int(data_limit/(1024**3))} ГБ" if data_limit >= 1024**3 else f"{int(data_limit/(1024*1024))} МБ" if data_limit > 0 else "∞"
    expire_at = user.get("expire_at", 0) or 0
    if expire_at == 0:
        days_left = "♾️ Без срока"
    else:
        delta = int((expire_at - datetime.now().timestamp()) / 86400)
        days_left = f"{delta} дней" if delta > 0 else "❗ Истёк"
    return used_str, limit_str, days_left
def kb_main():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🚀 Купить VPN", callback_data="buy_month"),
         InlineKeyboardButton(text="🎁 Бесплатный тест", callback_data="buy_trial")],
        [InlineKeyboardButton(text="📱 Как подключиться", callback_data="howto"),
         InlineKeyboardButton(text="🔑 Мой VPN", callback_data="my_vpn")],
        [InlineKeyboardButton(text="👥 Реферальная программа", callback_data="referral")],
[InlineKeyboardButton(text="ℹ️ Поддержка", url=SUPPORT)],
    ])
def kb_back():
    return InlineKeyboardMarkup(inline_keyboard=[[InlineKeyboardButton(text="🏠 Главное меню", callback_data="main")]])
def kb_my_vpn(is_premium=False):
    if is_premium:
        return InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="🔑 Мои ключи", callback_data="my_keys"),
             InlineKeyboardButton(text="🔄 Продлить", callback_data="buy_month")],
            [InlineKeyboardButton(text="👥 Рефералы", callback_data="referral"),
             InlineKeyboardButton(text="🏠 Меню", callback_data="main")],
        ])
    else:
        return InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="🔑 Мои ключи", callback_data="my_keys"),
             InlineKeyboardButton(text="💎 Купить премиум", callback_data="buy_month")],
            [InlineKeyboardButton(text="👥 Рефералы", callback_data="referral"),
             InlineKeyboardButton(text="🏠 Меню", callback_data="main")],
        ])
def kb_no_vpn():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🚀 Купить VPN", callback_data="buy_month")],
        [InlineKeyboardButton(text="🎁 Бесплатный тест", callback_data="buy_trial")],
        [InlineKeyboardButton(text="🏠 Главное меню", callback_data="main")],
    ])
def txt_welcome(name):
    return (f"🎉 <b>Добро пожаловать, {name}!</b>\n\n🌈 <b>Premium VPN Service</b>\n{D}\n"
            f"🚀 <b>Что вас ждёт:</b>\n  🔴 №1 по скорости в России\n  🟠 Обходит все глушилки\n"
            f"  🟡 Комфортная связь для вашего бизнеса\n  🟢 Работает на всех устройствах\n"
            f"  🔵 Оплата только через ⭐ Telegram Stars\n{D}\n👇 <b>Выберите действие:</b>")
def txt_keys(user, plan_key):
    used_str, limit_str, days_left = parse_user_info(user)
    k = user.get("_keys") or user.get("keys") or {}
    real_sub = user.get("sub_url","")

    def esc(t):
        for c in r"_*[]()~`>#+-=|{}.!":
            t = t.replace(c, f"\\{c}")
        return t

    lines = [
        f"✅ *VPN активирован\!*",
        f"📅 Осталось: *{esc(days_left)}*",
        f"📦 Трафик: *{esc(used_str)} / {esc(limit_str)}*",
        "",
    ]

    if real_sub:
        lines += [f"🔗 *Ссылка\-подписка:*", f"```\n{real_sub}\n```", ""]

    lines += ["🔑 *Ваши ключи:*"]
    parts = []
    if k.get("vless_de"):       parts.append(k["vless_de"])
    if k.get("hy2_de"):         parts.append(k["hy2_de"])
    if k.get("vless_fin"):      parts.append(k["vless_fin"])
    if k.get("hy2_fin"):        parts.append(k["hy2_fin"])
    if k.get("hy2_bridge_de"):  parts.append(k["hy2_bridge_de"])
    if k.get("hy2_bridge_fin"): parts.append(k["hy2_bridge_fin"])
    if parts:
        lines += ["```\n" + "\n".join(parts) + "\n```"]
    else:
        lines += ["⚠️ Ключи генерируются, подождите 1 минуту\."]

    lines += [
        esc("──────────────────"),
        "💡 Эти VPN\-ключи показывают лучшую скорость и стабильность при использовании в приложениях *V2Box* и *V2Tun*\.",
        "",
        f"📱 Android/iOS: *Happ VPN · Hiddify · v2Tun · v2Box*",
        f"💻 PC: *Hiddify Next*",
    ]
    return "\n".join(lines)
def txt_howto():
    return (f"📱 <b>Как подключиться к VPN</b>\n{D}\n\n"
            f"<b>📱 Android и iPhone:</b>\n\n"
            f"  🟣 <b>v2Tun</b>\n     <a href='https://play.google.com/store/apps/details?id=com.v2tun.android'>Android</a> · <a href='https://apps.apple.com/app/v2tun/id6476628951'>iOS</a>\n\n"
            f"  🟡 <b>v2Box</b>\n     <a href='https://play.google.com/store/apps/details?id=dev.hexasoftware.v2box'>Android</a> · <a href='https://apps.apple.com/app/v2box-v2ray-client/id6446814690'>iOS</a>\n\n"
            f"{D2}\n<b>💻 Windows / macOS / Linux:</b>\n\n"
            f"  🖥 <b>Hiddify Next</b>: <a href='https://github.com/hiddify/hiddify-next/releases'>Скачать</a>\n"
            f"  🖥 <b>v2rayN</b>: <a href='https://github.com/2dust/v2rayN/releases'>Скачать</a>\n\n"
            f"{D}\n1️⃣ Установите приложение\n2️⃣ Нажмите 🔑 <b>Мой VPN</b> → <b>Мои ключи</b>\n"
            f"3️⃣ Скопируйте ключ и вставьте в приложение\n\n💬 <a href='{SUPPORT}'>Поддержка</a>")
@dp.message(CommandStart())
async def cmd_start(msg: Message):
    args = msg.text.split()
    if len(args) > 1 and args[1].startswith("ref_"):
        try:
            referrer_id = int(args[1][4:])
            if referrer_id != msg.from_user.id:
                db_save_referral(referrer_id, msg.from_user.id)
        except: pass
    await msg.answer(txt_welcome("happVIP"), reply_markup=kb_main(), parse_mode="HTML")
@dp.callback_query(F.data == "main")
async def cb_main(cb: types.CallbackQuery):
    await cb.message.edit_text(txt_welcome("happVIP"), reply_markup=kb_main(), parse_mode="HTML")
    await cb.answer()
@dp.callback_query(F.data == "referral")
async def cb_referral(cb: types.CallbackQuery):
    tg_id = cb.from_user.id
    total_refs, buyers, total_bonus = db_get_stats(tg_id)
    ref_link = f"https://t.me/{BOT_USERNAME}?start=ref_{tg_id}"
    text = (f"👥 <b>Реферальная программа</b>\n{D}\n\n"
            f"🎁 <b>Как это работает:</b>\n"
            f"  • Поделитесь своей ссылкой\n"
            f"  • Друг покупает VPN по вашей ссылке\n"
            f"  • Вы получаете <b>+7 дней</b> за 1-ю покупку\n"
            f"  • <b>+14 дней</b> за 2-ю, <b>+21</b> за 3-ю и т.д.\n\n"
            f"{D2}\n📊 <b>Ваша статистика:</b>\n"
            f"  👤 Приглашено: <b>{total_refs}</b>\n"
            f"  💳 Купили VPN: <b>{buyers}</b>\n"
            f"  🎁 Заработано дней: <b>{total_bonus}</b>\n\n"
            f"{D2}\n🔗 <b>Ваша ссылка:</b>\n<code>{ref_link}</code>")
    await cb.message.edit_text(text, reply_markup=kb_back(), parse_mode="HTML", disable_web_page_preview=True)
    await cb.answer()
@dp.callback_query(F.data == "buy_trial")
async def cb_buy_trial(cb: types.CallbackQuery):
    await cb.message.edit_text(
        f"🎁 <b>Бесплатный тест</b>\n{D}\n📦 Трафик: <b>100 МБ</b>\n📅 Срок: <b>Без ограничений</b>\n💳 Цена: <b>Бесплатно</b>\n{D}\n🌍 Серверы: 🇷🇺 · 🇩🇪 · 🇫🇮\n⚡ VLESS Reality + Hysteria2\n{D2}\n👇 Нажмите для активации:",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="✅ Получить бесплатно", callback_data="confirm_trial")],
            [InlineKeyboardButton(text="◀️ Назад", callback_data="main")],
        ]), parse_mode="HTML")
    await cb.answer()
@dp.callback_query(F.data == "confirm_trial")
async def cb_confirm_trial(cb: types.CallbackQuery):
    await cb.answer()
    tg_id = cb.from_user.id
    existing = await get_user_by_tg(tg_id)
    if existing:
        await cb.message.edit_text("ℹ️ <b>У вас уже есть аккаунт!</b>\n\nИспользуйте <b>🔑 Мой VPN</b>.", reply_markup=kb_my_vpn(), parse_mode="HTML"); return
    user = await create_panel_user(tg_id, "trial")
    if user:
        await cb.message.edit_text(txt_keys(user, "trial"), reply_markup=kb_back(), parse_mode="MarkdownV2")
    else:
        await cb.message.edit_text("❌ Ошибка. Напишите в поддержку.", reply_markup=kb_back(), parse_mode="HTML")
@dp.callback_query(F.data == "buy_month")
async def cb_buy_month(cb: types.CallbackQuery):
    await cb.message.edit_text(
        f"🚀 <b>Тариф: 1 месяц</b>\n{D}\n📦 Трафик: <b>200 ГБ</b>\n📅 Срок: <b>30 дней</b>\n💳 Цена: <b>⭐ 250 Telegram Stars</b>\n{D}\n🌍 Серверы: 🇷🇺 · 🇩🇪 · 🇫🇮\n⚡ VLESS Reality + Hysteria2\n📱 iOS · Android · Windows · macOS\n{D2}\n👇 Нажмите для оплаты:",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="✅ Оплатить ⭐ 250 Stars", callback_data="confirm_month")],
            [InlineKeyboardButton(text="◀️ Назад", callback_data="main")],
        ]), parse_mode="HTML")
    await cb.answer()
@dp.callback_query(F.data == "confirm_month")
async def cb_confirm_month(cb: types.CallbackQuery):
    await bot.send_invoice(chat_id=cb.from_user.id, title="🚀 VPN 1 месяц",
        description="200 ГБ трафика · 30 дней · VLESS Reality + Hysteria2",
        payload=f"vpn_month_{cb.from_user.id}", currency="XTR",
        prices=[LabeledPrice(label="VPN 1 месяц", amount=250)])
    await cb.answer()
@dp.pre_checkout_query()
async def pre_checkout(q: PreCheckoutQuery):
    await q.answer(ok=True)
@dp.message(F.successful_payment)
async def on_payment(msg: Message):
    parts = msg.successful_payment.invoice_payload.split("_")
    if len(parts) < 2 or parts[0] != "vpn": return
    plan_key = parts[1]
    plan = PLANS.get(plan_key)
    if not plan: return
    await msg.answer("⭐ <b>Оплата получена!</b>\n\n⏳ Активируем ваш VPN...", parse_mode="HTML")
    tg_id = msg.from_user.id
    existing = await get_user_by_tg(tg_id)
    if existing:
        user = await extend_panel_user(tg_id, existing["user_id"] or existing["id"], plan_key) or existing
    else:
        user = await create_panel_user(tg_id, plan_key)
    if user:
        await msg.answer(txt_keys(user, plan_key), reply_markup=kb_back(), parse_mode="MarkdownV2")
    else:
        await msg.answer("❌ <b>Ошибка активации.</b>\nНапишите в поддержку.", reply_markup=kb_back(), parse_mode="HTML")
        return
    referrer_id = db_get_referrer(tg_id)
    if referrer_id:
        purchases_before = db_count_purchases(referrer_id, tg_id)
        bonus_days = REFERRAL_DAYS_PER_PURCHASE * (purchases_before + 1)
        db_save_purchase(referrer_id, tg_id, bonus_days)
        ok = await add_bonus_days(referrer_id, bonus_days)
        if ok:
            try:
                await bot.send_message(referrer_id,
                    f"🎉 <b>Реферальный бонус!</b>\n{D}\n"
                    f"Ваш друг совершил покупку #{purchases_before+1}\n"
                    f"Вы получили <b>+{bonus_days} дней</b> к подписке! 🎁",
                    parse_mode="HTML")
            except: pass
@dp.callback_query(F.data == "my_vpn")
async def cb_my_vpn_handler(cb: types.CallbackQuery):
    user = await get_user_by_tg(cb.from_user.id)
    if not user:
        await cb.message.edit_text("🔍 <b>Аккаунт не найден</b>\n\nВыберите тариф:", reply_markup=kb_no_vpn(), parse_mode="HTML")
    else:
        st = user.get("status","unknown")
        used_str, limit_str, days_left = parse_user_info(user)
        tl = user.get("data_limit", 0) or 0
        is_premium = tl >= 200 * 1024 * 1024 * 1024
        plan_label = "💎 Премиум" if is_premium else "🎁 Тестовый"
        await cb.message.edit_text(
            f"👤 <b>Мой VPN</b>\n{D}\n{'🟢' if st=='active' else '🔴'} Статус: <b>{st}</b>\n📦 Тариф: <b>{plan_label}</b>\n📅 Осталось: {days_left}\n📊 Трафик: <b>{used_str} / {limit_str}</b>\n{D}\n🌍 Серверы: 🇷🇺 · 🇩🇪 · 🇫🇮",
            reply_markup=kb_my_vpn(is_premium), parse_mode="HTML")
    await cb.answer()
@dp.callback_query(F.data == "my_keys")
async def cb_my_keys(cb: types.CallbackQuery):
    user = await get_user_by_tg(cb.from_user.id)
    if not user:
        await cb.answer("❌ Аккаунт не найден", show_alert=True); return
    tl = user.get("data_limit", 0) or 0
    plan_key = "month" if tl >= 200 * 1024 * 1024 * 1024 else "trial"
    await cb.message.edit_text(txt_keys(user, plan_key), reply_markup=kb_back(), parse_mode="MarkdownV2")
    await cb.answer()
@dp.callback_query(F.data == "howto")
async def cb_howto(cb: types.CallbackQuery):
    await cb.message.edit_text(txt_howto(), reply_markup=kb_back(), parse_mode="HTML", disable_web_page_preview=True)
    await cb.answer()
@dp.message(Command("admin"))
async def cmd_admin(msg: Message):
    if msg.from_user.id not in ADMIN_IDS: return
    try:
        users = await api_get("/api/users") or []
        active = sum(1 for u in users if isinstance(u, dict) and u.get("status")=="active")
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("SELECT COUNT(*) FROM referrals")
        total_refs = c.fetchone()[0]
        c.execute("SELECT COUNT(*) FROM ref_purchases")
        total_purchases = c.fetchone()[0]
        conn.close()
        await msg.answer(
            f"🛡 <b>Admin Panel</b>\n{D}\n"
            f"👥 Пользователей: <b>{len(users)}</b>\n"
            f"✅ Активных: <b>{active}</b>\n{D2}\n"
            f"👥 Рефералов: <b>{total_refs}</b>\n"
            f"💳 Покупок по рефералам: <b>{total_purchases}</b>",
            parse_mode="HTML")
    except Exception as e:
        await msg.answer(f"❌ Ошибка: {e}")
async def main():
    db_init()
    logger.info("🚀 HAPPVIP Bot starting with referral system...")
    await dp.start_polling(bot)
if __name__ == "__main__":
    asyncio.run(main())
