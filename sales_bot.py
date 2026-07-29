"""
QUANTORA - Free Download Bot
Sends indicator files for free
"""

import os
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, ContextTypes
from telegram.constants import ParseMode

# ── Config ────────────────────────────────────────────────────────────

BOT_TOKEN = "8671599679:AAE5CpPgbj7Al4uEs7EAPHWztI5cFFo_aPA"
ADMIN_ID = 5666485200
PRODUCTS_DIR = "/data/workspace/quantora-site"

# ── Products ──────────────────────────────────────────────────────────

PRODUCTS = {
    "mdx_divergence": {
        "name": "MDX MultiDivergence",
        "file": "MDX_MultiDivergence.mq5",
        "description": "موتور تشخیص واگرایی چند اسیلاتوری",
    }
}

# ── Bot Handlers ──────────────────────────────────────────────────────

async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    # Check if user wants a specific product
    if context.args and len(context.args) > 0:
        product_id = context.args[0].replace("free_", "")
        if product_id in PRODUCTS:
            await send_product(update, context, product_id)
            return
    
    keyboard = [
        [InlineKeyboardButton("📥 محصولات رایگان", callback_data="show_products")],
        [InlineKeyboardButton("❓ راهنما", callback_data="help")],
    ]
    
    await update.message.reply_text(
        "🌟 **به QUANTORA خوش آمدید!** 🌟\n\n"
        "فروشگاه اندیکاتورهای حرفه‌ای MetaTrader 5\n\n"
        "━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
        "💎 اندیکاتورهای بدون ریپینت\n"
        "⚡ تحویل خودکار و رایگان\n"
        "🔒 کد باز و قابل بررسی\n\n"
        "━━━━━━━━━━━━━━━━━━━━━━━━",
        reply_markup=InlineKeyboardMarkup(keyboard),
        parse_mode=ParseMode.MARKDOWN
    )

async def show_products(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    text = "📥 **محصولات رایگان:**\n\n━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
    
    for pid, product in PRODUCTS.items():
        text += f"💎 **{product['name']}**\n"
        text += f"📝 {product['description']}\n"
        text += f"💰 قیمت: **رایگان** 🎁\n"
        text += f"━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
    
    keyboard = [[InlineKeyboardButton(f"📥 دانلود {PRODUCTS['mdx_divergence']['name']}", callback_data="free_mdx_divergence")]]
    
    await query.edit_message_text(text, reply_markup=InlineKeyboardMarkup(keyboard), parse_mode=ParseMode.MARKDOWN)

async def free_download(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    product_id = query.data.replace("free_", "")
    await send_product(update, context, product_id, is_callback=True)

async def send_product(update: Update, context: ContextTypes.DEFAULT_TYPE, product_id: str, is_callback: bool = False):
    if product_id not in PRODUCTS:
        if is_callback:
            await update.callback_query.edit_message_text("❌ محصول یافت نشد!")
        else:
            await update.message.reply_text("❌ محصول یافت نشد!")
        return
    
    product = PRODUCTS[product_id]
    file_path = os.path.join(PRODUCTS_DIR, product["file"])
    
    if os.path.exists(file_path):
        # Notify admin
        user = update.callback_query.from_user if is_callback else update.message.from_user
        await context.bot.send_message(
            chat_id=ADMIN_ID,
            text=f"📥 **دانلود جدید!**\n\n"
                 f"📦 محصول: {product['name']}\n"
                 f"👤 کاربر: @{user.username or user.first_name}\n"
                 f"🆔 آیدی: `{user.id}`",
            parse_mode=ParseMode.MARKDOWN
        )
        
        # Send file
        caption = f"✅ **{product['name']}**\n\n"
        caption += f"📝 {product['description']}\n\n"
        caption += "━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
        caption += "💡 **نحوه نصب:**\n"
        caption += "۱. فایل رو در MetaTrader 5 کپی کنید\n"
        caption += "۲. اندیکاتور رو به چارت اضافه کنید\n"
        caption += "۳. تنظیمات دلخواه رو اعمال کنید\n\n"
        caption += "━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
        caption += "📞 **پشتیبانی:** @leili9772r\n"
        caption += "💬 **کانال:** @ict_shirazz"
        
        if is_callback:
            await update.callback_query.edit_message_text(
                "✅ فایل با موفقیت ارسال شد!\n\nاز دانلود لذت ببرید! 🎉",
                parse_mode=ParseMode.MARKDOWN
            )
        
        await context.bot.send_document(
            chat_id=user.id,
            document=open(file_path, 'rb'),
            caption=caption,
            parse_mode=ParseMode.MARKDOWN
        )
    else:
        await update.message.reply_text("⚠️ فایل یافت نشد. با پشتیبانی تماس بگیرید.")

async def help_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    await query.edit_message_text(
        "❓ **راهنما**\n\n"
        "━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
        "📥 **دانلود:** روی محصول کلیک کنید\n"
        "📦 **فایل:** خودکار ارسال میشه\n"
        "💡 **نصب:** در MetaTrader 5 استفاده کنید\n\n"
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
    app.add_handler(CallbackQueryHandler(free_download, pattern="^free_"))
    app.add_handler(CallbackQueryHandler(help_cmd, pattern="^help$"))
    
    print("🤖 QUANTORA Free Download Bot Started!")
    print("Press Ctrl+C to stop")
    
    app.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == "__main__":
    main()
