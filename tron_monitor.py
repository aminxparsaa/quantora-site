"""
TRON Payment System - Auto File Delivery
"""

import os
import json
import time
import hashlib
import requests
from datetime import datetime
from typing import Dict, Optional

# ── Config ────────────────────────────────────────────────────────────

TRON_ADDRESS = "TLVXE23QE2hjMb8J8SsjUyhQt22T8fn5wP"
TRONGRID_API = "https://api.trongrid.io"
CHECK_INTERVAL = 30  # seconds
ORDERS_FILE = "orders.json"
CONFIRMATIONS_REQUIRED = 1  # TRON confirmations

# ── Products ──────────────────────────────────────────────────────────

PRODUCTS = {
    "mdx_divergence": {
        "name": "MDX MultiDivergence",
        "file": "MDX_MultiDivergence.mq5",
        "price_trx": 500,  # ~$50 in TRX
        "price_usd": 50,
    }
}

# ── Order Management ──────────────────────────────────────────────────

class OrderManager:
    def __init__(self):
        self.orders = self._load_orders()
    
    def _load_orders(self) -> Dict:
        if os.path.exists(ORDERS_FILE):
            with open(ORDERS_FILE, 'r') as f:
                return json.load(f)
        return {}
    
    def _save_orders(self):
        with open(ORDERS_FILE, 'w') as f:
            json.dump(self.orders, f, indent=2)
    
    def create_order(self, user_id: int, username: str, product_id: str) -> Dict:
        """Create a new order."""
        order_id = hashlib.md5(f"{user_id}{time.time()}".encode()).hexdigest()[:8]
        
        order = {
            "id": order_id,
            "user_id": user_id,
            "username": username,
            "product_id": product_id,
            "amount_trx": PRODUCTS[product_id]["price_trx"],
            "address": TRON_ADDRESS,
            "status": "pending",
            "created_at": datetime.now().isoformat(),
            "tx_hash": None,
            "confirmed_at": None,
        }
        
        self.orders[order_id] = order
        self._save_orders()
        return order
    
    def get_pending_orders(self) -> list:
        """Get all pending orders."""
        return [o for o in self.orders.values() if o["status"] == "pending"]
    
    def confirm_order(self, order_id: str, tx_hash: str) -> bool:
        """Confirm an order with transaction hash."""
        if order_id in self.orders:
            self.orders[order_id]["status"] = "confirmed"
            self.orders[order_id]["tx_hash"] = tx_hash
            self.orders[order_id]["confirmed_at"] = datetime.now().isoformat()
            self._save_orders()
            return True
        return False
    
    def get_order(self, order_id: str) -> Optional[Dict]:
        """Get order by ID."""
        return self.orders.get(order_id)

# ── TRON Monitor ──────────────────────────────────────────────────────

class TronMonitor:
    def __init__(self):
        self.api_base = TRONGRID_API
    
    def get_transactions(self, address: str) -> list:
        """Get recent transactions for an address."""
        url = f"{self.api_base}/v1/accounts/{address}/transactions"
        try:
            response = requests.get(url, params={
                "limit": 20,
                "only_to": "true",
                "order_by": "block_timestamp,desc"
            }, timeout=10)
            if response.status_code == 200:
                data = response.json()
                return data.get("data", [])
        except Exception as e:
            print(f"Error fetching transactions: {e}")
        return []
    
    def verify_payment(self, address: str, amount_trx: int, within_seconds: int = 3600) -> Optional[str]:
        """Verify if payment was received."""
        transactions = self.get_transactions(address)
        
        for tx in transactions:
            # Check if transaction is recent
            tx_time = tx.get("block_timestamp", 0) / 1000
            if time.time() - tx_time > within_seconds:
                continue
            
            # Check contract data
            contract = tx.get("raw_data", {}).get("contract", [{}])[0]
            if contract.get("type") == "TransferContract":
                params = contract.get("parameter", {}).get("value", {})
                to_address = params.get("to_address", "")
                amount = params.get("amount", 0)
                
                if to_address == address and amount >= amount_trx * 1_000_000:  # TRX to SUN
                    return tx.get("txID")
        
        return None

# ── Main Monitor Loop ────────────────────────────────────────────────

def monitor_payments():
    """Main payment monitoring loop."""
    order_manager = OrderManager()
    tron_monitor = TronMonitor()
    
    print("🔍 TRON Payment Monitor Started")
    print(f"📍 Address: {TRON_ADDRESS}")
    print(f"⏱️ Check interval: {CHECK_INTERVAL}s")
    print("Press Ctrl+C to stop\n")
    
    while True:
        try:
            pending_orders = order_manager.get_pending_orders()
            
            for order in pending_orders:
                tx_hash = tron_monitor.verify_payment(
                    order["address"],
                    order["amount_trx"]
                )
                
                if tx_hash:
                    print(f"✅ Payment confirmed for order {order['id']}")
                    order_manager.confirm_order(order["id"], tx_hash)
                    
                    # Here you would call the Telegram bot to send the file
                    # send_file_to_user(order["user_id"], order["product_id"])
            
            time.sleep(CHECK_INTERVAL)
            
        except KeyboardInterrupt:
            print("\n👋 Monitor stopped")
            break
        except Exception as e:
            print(f"❌ Error: {e}")
            time.sleep(CHECK_INTERVAL)

if __name__ == "__main__":
    monitor_payments()
