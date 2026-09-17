//+------------------------------------------------------------------+
//|                                  M1_SMC_BuyLow_SellHigh.mq5      |
//|                               Copyright 2026, Smart SMC Scalper  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "16.00"

#include <Trade\Trade.mqh>
CTrade trade;

// --- Input Parameters ---
input group "--- Settings Layering ---"
input double   InpLotSize            = 0.01;     // Lot per Entry
input int      InpLayerCount         = 5;        // Eksekusi Instant 5 Layer
input ulong    InpMagicNumber        = 334455;   // Magic Number EA

input group "--- Target Profit & Basket Loss (Dalam USC) ---"
input double   InpTargetProfitUSC    = 0.50;     // Target Profit Gabungan 5 Layer (0.50 USC = @0.10 USC/layer)
input double   InpBasketMaxLossUSC   = 12.0;     // HARD BASKET CUT LOSS TOTAL KESELURUHAN (-12 USC)

input group "--- SMC Zone Settings (M1) ---"
input int      InpLookbackCandles    = 30;       // Range 30 Candle M1 untuk Mencari High & Low Zone

datetime lastTradeTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   Print("EA SMC Buy Low & Sell High (M1) Berhasil Aktif!");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1. KELOLA TOTAL BASKET PROFIT (>= 0.50 USC) & BASKET CUT LOSS (-12 USC TOTAL)
   ManageBasketPL();

   // 2. Jeda 3 detik antar eksekusi
   if(TimeCurrent() - lastTradeTime < 3) return;

   // 3. Eksekusi 5 Layer jika Posisi Kosong
   if(CountPositions() == 0)
     {
      ExecuteBuyLowSellHigh();
     }
  }

//+------------------------------------------------------------------+
//| MANAGEMENT TOTAL BASKET PROFIT & LOSS (-12 USC TOTAL)            |
//+------------------------------------------------------------------+
void ManageBasketPL()
  {
   if(CountPositions() == 0) return;

   double totalProfit = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
        {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
           {
            totalProfit += (PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP));
           }
        }
     }

   // A. FAST PROFIT CUT ALL (Total >= 0.50 USC)
   if(totalProfit >= InpTargetProfitUSC)
     {
      CloseAllPositions();
      Print("BASKET PROFIT TERCAPAI: ", totalProfit, " USC -> CLOSE ALL!");
      lastTradeTime = TimeCurrent();
     }
   // B. HARD BASKET CUT LOSS (Total <= -12.0 USC)
   else if(totalProfit <= -InpBasketMaxLossUSC)
     {
      CloseAllPositions();
      Print("TOTAL BASKET MINUS MEMBENGKAK (", totalProfit, " USC) -> FAST BASKET CUT ALL (-12 USC)!");
      lastTradeTime = TimeCurrent();
     }
  }

//+------------------------------------------------------------------+
//| FUNGSI SAPU BERSIH / CLOSE ALL POSISI                            |
//+------------------------------------------------------------------+
void CloseAllPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
        {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
           {
            trade.PositionClose(ticket);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| LOGIKA AKURAT: BUY HANYA DI BAWAH, SELL HANYA DI ATAS            |
//+------------------------------------------------------------------+
void ExecuteBuyLowSellHigh()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   if(CopyRates(_Symbol, _Period, 0, InpLookbackCandles, rates) < InpLookbackCandles) return;

   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // 1. CARI HARGA TERTINGGI (SUPPLY/PUCUK) & TERENDAH (DEMAND/DASAR) 30 CANDLE TERAKHIR
   double highestHigh = rates[1].high;
   double lowestLow   = rates[1].low;

   for(int i = 1; i < InpLookbackCandles; i++)
     {
      if(rates[i].high > highestHigh) highestHigh = rates[i].high;
      if(rates[i].low < lowestLow)   lowestLow   = rates[i].low;
     }

   double rangeZone = highestHigh - lowestLow;
   if(rangeZone <= 0) return;

   // Hitung Posisi Harga Saat Ini dalam Persentase Range (0% = Paling Dasar, 100% = Paling Pucuk)
   double currentPriceLevel = (bid - lowestLow) / rangeZone;

   // Deteksi Konfirmasi Candle M1 Terakhir
   bool isCandleBull = rates[0].close > rates[0].open;
   bool isCandleBear = rates[0].close < rates[0].open;

   // --- ATURAN FINAL SMC ---

   // LOGIKA BUY: Hanya jika harga berada di AREA BAWAH/DASAR (< 35% dari Range) DAN Candle Mulai Memantul Hijau
   if(currentPriceLevel <= 0.35 && isCandleBull)
     {
      Print("Harga di Area DISCOUNT/DASAR (Level: ", currentPriceLevel * 100, "%) & Memantul Naik -> TEMBAK 5 BUY!");
      for(int k = 0; k < InpLayerCount; k++)
        {
         trade.Buy(InpLotSize, _Symbol, ask, 0, 0, "SMC Buy Low");
        }
      lastTradeTime = TimeCurrent();
     }
   // LOGIKA SELL: Hanya jika harga berada di AREA ATAS/PUCUK (> 65% dari Range) DAN Candle Mulai Memantul Merah
   else if(currentPriceLevel >= 0.65 && isCandleBear)
     {
      Print("Harga di Area PREMIUM/PUCUK (Level: ", currentPriceLevel * 100, "%) & Memantul Turun -> TEMBAK 5 SELL!");
      for(int k = 0; k < InpLayerCount; k++)
        {
         trade.Sell(InpLotSize, _Symbol, bid, 0, 0, "SMC Sell High");
        }
      lastTradeTime = TimeCurrent();
     }
   else
     {
      // Harga di tengah-tengah (Area Bahaya/Terapung) -> BATALKAN ENTRY
      Print("Harga Berada di Tengah Range (Level: ", currentPriceLevel * 100, "%) -> TAHAN ENTRY (Mencegah Trap)");
     }
  }

//+------------------------------------------------------------------+
//| HELPER FUNCTION                                                  |
//+------------------------------------------------------------------+
int CountPositions()
  {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(PositionGetTicket(i) > 0)
        {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            count++;
        }
     }
   return count;
  }
//+------------------------------------------------------------------+
