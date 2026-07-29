"""
QUANTORA - Telegram Sales Bot
Handles orders and file delivery
"""

import os
import json
import hashlib
import time
import requests
from datetime import datetime
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, MessageHandler, CallbackQueryHandler, ContextTypes, filters
from telegram.constants import ParseMode

# ── Config ────────────────────────────────────────────────────────────

BOT_TOKEN = "YOUR_BOT_TOKEN_HERE"  # Create a new bot via @BotFather
TRON_ADDRESS = "TLVXE23QE2hjMb8J8SsjUyhQt22T8fn5wP"
ADMIN_ID = 5666485200
PRODUCTS_DIR = "/data/workspace/quantora-site"

# ── Products ──────────────────────────────────────────────────────────

PRODUCTS = {
    "mdx_divergence": {
        "name": "MDX MultiDivergence",
        "file": "MDX_MultiDivergence.mq5",
        "price_trx": 500,
        "price_usd": 50,
        "description": "Multi-Oscillator Weighted Divergence Engine",
    }
}

# ── Orders ────────────────────────────────────────────────────────────

ORDERS_FILE = "/data/workspace/quantora-site/orders.json"

def load_orders():
    if os.path.exists(ORDERS_FILE):
        with open(ORDERS_FILE, 'r') as f:
            return json.load(f)
    return {}

def save_orders(orders):
    with open(ORDERS_FILE, 'w') as f:
        json.dump(orders, f, indent=2)

def create_order(user_id, username, product_id):
    orders = load_orders()
    order_id = hashlib.md5(f"{user_id}{time.time()}".encode()).hexdigest()[:8]
    
    orders[order_id] = {
        "id": order_id,
        "user_id": user_id,
        "username": username,
        "product_id": product_id,
        "amount_trx": PRODUCTS[product_id]["price_trx"],
        "status": "pending",
        "created_at": datetime.now().isoformat(),
        "tx_hash": None,
    }
    
    save_orders(orders)
    return orders[order_id]

def confirm_order(order_id, tx_hash):
    orders = load_orders()
    if order_id in orders:
        orders[order_id]["status"] = "confirmed"
        orders[order_id]["tx_hash"] = tx_hash
        orders[order_id]["confirmed_at"] = datetime.now().isoformat()
        save_orders(orders)
        return True
    return False

# ── Bot Handlers ──────────────────────────────────────────────────────

async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    keyboard = [
        [InlineKeyboardButton("🛒 مشاهده محصولات", callback_data="show_products")],
        [InlineKeyboardButton("📦 سفارشات من", callback_data="my_orders")],
        [InlineKeyboardButton("❓ راهنما", callback_data="help")],
    ]
    
    await update.message.reply_text(
        "🌟 **به QUANTORA خوش آمدید!** 🌟\n\n"
        "فروشگاه اندیکاتورهای حرفه‌ای MetaTrader 5\n\n"
        "━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
        "💎 اندیکاتورهای بدون ریپینت\n"
        "⚡ تحویل خودکار پس از پرداخت\n"
        "🔒 پرداخت امن با ترون (TRX)\n\n"
        "━━━━━━━━━━━━━━━━━━━━━━━━",
        reply_markup=InlineKeyboardMarkup(keyboard),
        parse_mode=ParseMode.MARKDOWN
    )

async def show_products(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    text = "🛒 **محصولات ما:**\n\n━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
    
    for pid, product in PRODUCTS.items():
        text += f"💎 **{product['name']}**\n"
        text += f"📝 {product['description']}\n"
        text += f"💰 قیمت: **{product['price_trx']} TRX** (~${product['price_usd']})\n"
        text += f"━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
    
    keyboard = [[InlineKeyboardButton(f"🛒 خرید {PRODUCTS['mdx_divergence']['name']}", callback_data="buy_mdx_divergence")]]
    
    await query.edit_message_text(text, reply_markup=InlineKeyboardMarkup(keyboard), parse_mode=ParseMode.MARKDOWN)

async def buy_product(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    product_id = query.data.replace("buy_", "")
    if product_id not in PRODUCTS:
        await query.edit_message_text("❌ محصول یافت نشد!")
        return
    
    product = PRODUCTS[product_id]
    user_id = query.from_user.id
    username = query.from_user.username or query.from_user.first_name
    
    # Create order
    order = create_order(user_id, username, product_id)
    
    text = f"""🛒 **سفارش جدید**

━━━━━━━━━━━━━━━━━━━━━━━━

📦 **محصول:** {product['name']}
💰 **مبلغ:** {product['price_trx']} TRX (~${product['price_usd']})
🆔 **شناسه سفارش:** `{order['id']}`

━━━━━━━━━━━━━━━━━━━━━━━━

💳 **آدرس پرداخت ترون:**

`{TRON_ADDRESS}`

⚠️ **مهم:** فقط **{product['price_trx']} TRX** ارسال کنید!

━━━━━━━━━━━━━━━━━━━━━━━━

📋 **مراحل پرداخت:**

۱. کیف پول ترون خود باز کنید
۲. آدرس بالا رو کپی کنید
۳. **دقیقاً {product['price_trx']} TRX** ارسال کنید
۴. هش تراکنش (TxID) رو کپی کنید
۵. در ربات بفرستید

━━━━━━━━━━━━━━━━━━━━━━━━

⏰ سفارش شما **۳۰ دقیقه** اعتبار دارد."""
    
    keyboard = [
        [InlineKeyboardButton("✅ پرداخت کردم", callback_data=f"paid_{order['id']}")],
        [InlineKeyboardButton("❌ لغو سفارش", callback_data=f"cancel_{order['id']}")],
    ]
    
    await query.edit_message_text(text, reply_markup=InlineKeyboardMarkup(keyboard), parse_mode=ParseMode.MARKDOWN)

async def payment_received(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    order_id = query.data.replace("paid_", "")
    
    await query.edit_message_text(
        f"📝 **لطفاً هش تراکنش (TxID) رو بفرستید:**\n\n"
        f"شناسه سفارش: `{order_id}`\n\n"
        f"💡 هش تراکنش یک رشته ۶۴ کاراکتری هست که بعد از پرداخت در کیف پول نمایش داده میشه.",
        parse_mode=ParseMode.MARKDOWN
    )
    
    context.user_data["waiting_tx"] = order_id

async def handle_tx_hash(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if "waiting_tx" not in context.user_data:
        return
    
    tx_hash = update.message.text.strip()
    order_id = context.user_data.pop("waiting_tx")
    
    # Validate TX hash format (64 hex chars)
    if len(tx_hash) != 64 or not all(c in '0123456789abcdefABCDEF' for c in tx_hash):
        await update.message.reply_text("❌ فرمت هش تراکنش نامعتبر است. دوباره تلاش کنید.")
        return
    
    # Confirm order
    if confirm_order(order_id, tx_hash):
        orders = load_orders()
        order = orders[order_id]
        product = PRODUCTS[order["product_id"]]
        
        # Notify admin
        await context.bot.send_message(
            chat_id=ADMIN_ID,
            text=f"🔔 **سفارش جدید تأیید شد!**\n\n"
                 f"📦 محصول: {product['name']}\n"
                 f"👤 کاربر: @{order['username']}\n"
                 f"🆔 شناسه: `{order_id}`\n"
                 f"🔗 TxID: `{tx_hash}`\n\n"
                 f"💡 فایل رو به کاربر ارسال کنید.",
            parse_mode=ParseMode.MARKDOWN
        )
        
        # Send file to user
        file_path = os.path.join(PRODUCTS_DIR, product["file"])
        if os.path.exists(file_path):
            await update.message.reply_document(
                document=open(file_path, 'rb'),
                caption=f"✅ **پرداخت تأیید شد!**\n\n"
                        f"📦 محصول: {product['name']}\n"
                        f"🔗 TxID: `{tx_hash}`\n\n"
                        f"💡 فایل رو در MetaTrader 5 نصب کنید.\n"
                        f"📞 پشتیبانی: @leili9772r",
                parse_mode=ParseMode.MARKDOWN
            )
        else:
            await update.message.reply_text("⚠️ فایل یافت نشد. با پشتیبانی تماس بگیرید.")
    else:
        await update.message.reply_text("❌ خطا در تأیید سفارش. دوباره تلاش کنید.")

async def my_orders(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    orders = load_orders()
    user_orders = [o for o in orders.values() if o["user_id"] == query.from_user.id]
    
    if not user_orders:
        await query.edit_message_text("📦 **سفارشی ندارید.**", parse_mode=ParseMode.MARKDOWN)
        return
    
    text = "📦 **سفارشات شما:**\n\n━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
    
    for order in user_orders[-5:]:  # Last 5 orders
        product = PRODUCTS.get(order["product_id"], {})
        status_emoji = "✅" if order["status"] == "confirmed" else "⏳"
        text += f"{status_emoji} **{order['id']}**\n"
        text += f"   📦 {product.get('name', 'نامشخص')}\n"
        text += f"   💰 {order['amount_trx']} TRX\n"
        text += f"   📅 {order['created_at'][:16]}\n\n"
    
    await query.edit_message_text(text, parse_mode=ParseMode.MARKDOWN)

async def help_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    await query.edit_message_text(
        "❓ **راهنما**\n\n"
        "━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
        "🛒 **خرید:** روی محصول کلیک کنید\n"
        "💳 **پرداخت:** ترون (TRX) ارسال کنید\n"
        "📋 **تحویل:** فایل خودکار ارسال میشه\n\n"
        "━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
        "📞 **پشتیبانی:** @leili9772r\n"
        "💬 **کانال:** @ict_shirazz",
        parse_mode=ParseMode.MARKDOWN
    )

# ── Main ──────────────────────────────────────────────────────────────

def main():
    app = Application.builder().token(BOT_TOKEN).build()
    
    # Handlers
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CallbackQueryHandler(show_products, pattern="^show_products$"))
    app.add_handler(CallbackQueryHandler(buy_product, pattern="^buy_"))
    app.add_handler(CallbackQueryHandler(payment_received, pattern="^paid_"))
    app.add_handler(CallbackQueryHandler(my_orders, pattern="^my_orders$"))
    app.add_handler(CallbackQueryHandler(help_cmd, pattern="^help$"))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_tx_hash))
    
    print("🤖 QUANTORA Sales Bot Started!")
    print("Press Ctrl+C to stop")
    
    app.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == "__main__":
    main()
