import asyncio
import logging
from aiogram import Bot, Dispatcher, types, F
from aiogram.filters import Command
from aiogram.types import InlineKeyboardMarkup, InlineKeyboardButton, ReplyKeyboardMarkup, KeyboardButton
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.memory import MemoryStorage
import sqlite3
import os
import time
import secrets

logging.basicConfig(level=logging.INFO)

DB_PATH = '/opt/vpn_panel/backend/vpn_panel.db'

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def get_settings():
    conn = get_db()
    rows = conn.execute("SELECT key, value FROM settings").fetchall()
    conn.close()
    return {r['key']: r['value'] for r in rows}

def fmt_bytes(b):
    if not b: return '0 MB'
    if b >= 1073741824: return f'{b/1073741824:.2f} GB'
    return f'{b/1048576:.1f} MB'

def fmt_date(ts):
    if not ts: return '∞'
    return time.strftime('%d.%m.%Y', time.localtime(ts))

# ===== KEYBOARDS =====
def main_kb():
    return ReplyKeyboardMarkup(keyboard=[
        [KeyboardButton(text='📊 Мой профиль'), KeyboardButton(text='🔑 Мои ключи')],
        [KeyboardButton(text='📈 Статистика'), KeyboardButton(text='💳 Продлить')],
        [KeyboardButton(text='📞 Поддержка'), KeyboardButton(text='ℹ️ Помощь')]
    ], resize_keyboard=True)

def extend_kb():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text='📅 +30 дней', callback_data='extend_30')],
        [InlineKeyboardButton(text='📅 +90 дней', callback_data='extend_90')],
        [InlineKeyboardButton(text='📅 +180 дней', callback_data='extend_180')],
        [InlineKeyboardButton(text='❌ Отмена', callback_data='cancel')]
    ])

async def main():
    settings = get_settings()
    token = settings.get('tg_bot_token', '')
    if not token:
        print('❌ Токен бота не настроен в Settings')
        return

    bot = Bot(token=token)
    dp = Dispatcher(storage=MemoryStorage())

    # ===== /start =====
    @dp.message(Command('start'))
    async def cmd_start(msg: types.Message):
        tg_id = msg.from_user.id
        conn = get_db()
        user = conn.execute(
            "SELECT * FROM users WHERE telegram_id=?", (tg_id,)
        ).fetchone()
        conn.close()

        if user:
            await msg.answer(
                f'👋 Добро пожаловать, <b>{msg.from_user.first_name}</b>!\n\n'
                f'🔐 Ваш аккаунт: <code>{user["username"]}</code>\n'
                f'📊 Статус: <b>{user["status"]}</b>\n'
                f'📅 Действует до: <b>{fmt_date(user["expire_at"])}</b>',
                parse_mode='HTML',
                reply_markup=main_kb()
            )
        else:
            await msg.answer(
                f'👋 Привет, <b>{msg.from_user.first_name}</b>!\n\n'
                f'❌ Ваш аккаунт не найден.\n'
                f'Обратитесь к администратору для получения доступа.\n\n'
                f'Ваш Telegram ID: <code>{tg_id}</code>',
                parse_mode='HTML'
            )

    # ===== Профиль =====
    @dp.message(F.text == '📊 Мой профиль')
    async def profile(msg: types.Message):
        tg_id = msg.from_user.id
        conn = get_db()
        user = conn.execute("SELECT * FROM users WHERE telegram_id=?", (tg_id,)).fetchone()
        conn.close()
        if not user:
            await msg.answer('❌ Аккаунт не найден')
            return
        used = fmt_bytes(user['data_used'] or 0)
        limit = fmt_bytes(user['data_limit']) if user['data_limit'] else '∞'
        pct = round((user['data_used'] or 0) / user['data_limit'] * 100) if user['data_limit'] else 0
        bar = '█' * (pct // 10) + '░' * (10 - pct // 10) if user['data_limit'] else '∞∞∞∞∞∞∞∞∞∞'
        expires = fmt_date(user['expire_at'])
        days_left = round((user['expire_at'] - time.time()) / 86400) if user['expire_at'] else 999
        await msg.answer(
            f'📊 <b>Ваш профиль</b>\n\n'
            f'👤 Логин: <code>{user["username"]}</code>\n'
            f'🟢 Статус: <b>{user["status"]}</b>\n\n'
            f'📦 Трафик:\n'
            f'<code>{bar}</code> {pct}%\n'
            f'Использовано: <b>{used}</b> / <b>{limit}</b>\n\n'
            f'📅 Истекает: <b>{expires}</b>\n'
            f'⏳ Осталось: <b>{days_left} дней</b>',
            parse_mode='HTML',
            reply_markup=main_kb()
        )

    # ===== Ключи =====
    @dp.message(F.text == '🔑 Мои ключи')
    async def my_keys(msg: types.Message):
        tg_id = msg.from_user.id
        conn = get_db()
        user = conn.execute("SELECT * FROM users WHERE telegram_id=?", (tg_id,)).fetchone()
        conn.close()
        if not user:
            await msg.answer('❌ Аккаунт не найден')
            return
        settings = get_settings()
        domain = settings.get('panel_domain', '')
        keys = []
        if user['subscription_url']: keys.append(('🌍 VLESS Главный', user['subscription_url']))
        if user['hysteria2_url']: keys.append(('⚡ HY2 Главный', user['hysteria2_url']))
        if user['vless_main_bridge']: keys.append(('🌉 VLESS Мост', user['vless_main_bridge']))
        if user['hy2_main_bridge']: keys.append(('🌉 HY2 Мост', user['hy2_main_bridge']))
        if user['vless_ru75']: keys.append(('🇷🇺 VLESS RU75', user['vless_ru75']))
        if user['hy2_ru75']: keys.append(('🇷🇺 HY2 RU75', user['hy2_ru75']))
        if user['sub_token'] and domain:
            sub_url = f"{domain}/sub/{user['sub_token']}"
            keys.insert(0, ('🔗 Ссылка подписки', sub_url))
        if not keys:
            await msg.answer('❌ Ключи не найдены')
            return
        await msg.answer('🔑 <b>Ваши ключи:</b>', parse_mode='HTML')
        for label, key in keys:
            await msg.answer(
                f'{label}:\n<code>{key}</code>',
                parse_mode='HTML'
            )
        await msg.answer('✅ Нажмите на ключ чтобы скопировать', reply_markup=main_kb())

    # ===== Статистика =====
    @dp.message(F.text == '📈 Статистика')
    async def stats(msg: types.Message):
        tg_id = msg.from_user.id
        conn = get_db()
        user = conn.execute("SELECT * FROM users WHERE telegram_id=?", (tg_id,)).fetchone()
        conn.close()
        if not user:
            await msg.answer('❌ Аккаунт не найден')
            return
        used = fmt_bytes(user['data_used'] or 0)
        limit = fmt_bytes(user['data_limit']) if user['data_limit'] else '∞'
        await msg.answer(
            f'📈 <b>Статистика использования</b>\n\n'
            f'📥 Использовано: <b>{used}</b>\n'
            f'📦 Лимит: <b>{limit}</b>\n'
            f'📅 До: <b>{fmt_date(user["expire_at"])}</b>',
            parse_mode='HTML',
            reply_markup=main_kb()
        )

    # ===== Продление =====
    @dp.message(F.text == '💳 Продлить')
    async def extend_menu(msg: types.Message):
        await msg.answer(
            '💳 <b>Продление подписки</b>\n\nВыберите период:',
            parse_mode='HTML',
            reply_markup=extend_kb()
        )

    @dp.callback_query(F.data.startswith('extend_'))
    async def extend_callback(call: types.CallbackQuery):
        days = int(call.data.split('_')[1])
        tg_id = call.from_user.id
        conn = get_db()
        user = conn.execute("SELECT * FROM users WHERE telegram_id=?", (tg_id,)).fetchone()
        if not user:
            await call.answer('❌ Аккаунт не найден')
            conn.close()
            return
        now = int(time.time())
        current = max(user['expire_at'] or now, now)
        new_expire = current + days * 86400
        conn.execute("UPDATE users SET expire_at=?, status='active' WHERE telegram_id=?", (new_expire, tg_id))
        conn.commit()
        conn.close()
        await call.message.edit_text(
            f'✅ <b>Подписка продлена на {days} дней!</b>\n\n'
            f'📅 Новая дата: <b>{fmt_date(new_expire)}</b>',
            parse_mode='HTML'
        )
        await call.answer('✅ Продлено!')

    @dp.callback_query(F.data == 'cancel')
    async def cancel_cb(call: types.CallbackQuery):
        await call.message.delete()
        await call.answer('Отменено')

    # ===== Поддержка =====
    @dp.message(F.text == '📞 Поддержка')
    async def support(msg: types.Message):
        settings = get_settings()
        admin_id = settings.get('tg_admin_id', '')
        await msg.answer(
            f'📞 <b>Поддержка</b>\n\nДля связи с администратором напишите:\n@admin\n\nВаш ID: <code>{msg.from_user.id}</code>',
            parse_mode='HTML',
            reply_markup=main_kb()
        )

    # ===== Помощь =====
    @dp.message(F.text == 'ℹ️ Помощь')
    async def help_cmd(msg: types.Message):
        await msg.answer(
            '❓ <b>Помощь</b>\n\n'
            '📊 <b>Мой профиль</b> — информация об аккаунте\n'
            '🔑 <b>Мои ключи</b> — получить ключи подключения\n'
            '📈 <b>Статистика</b> — использование трафика\n'
            '💳 <b>Продлить</b> — продление подписки\n'
            '📞 <b>Поддержка</b> — связь с администратором',
            parse_mode='HTML',
            reply_markup=main_kb()
        )

    print('✅ Бот запущен!')
    await dp.start_polling(bot)

if __name__ == '__main__':
    asyncio.run(main())
