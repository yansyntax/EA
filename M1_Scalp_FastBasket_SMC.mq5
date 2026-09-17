//+------------------------------------------------------------------+
//|                                   M1_Scalp_FastBasket_SMC.mq5    |
//|                               Copyright 2026, Smart SMC Scalper  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "15.00"

#include <Trade\Trade.mqh>
CTrade trade;

// --- Input Parameters ---
input group "--- Settings Layering ---"
input double   InpLotSize            = 0.01;     // Lot per Entry
input int      InpLayerCount         = 5;        // Eksekusi Instant 5 Layer
input ulong    InpMagicNumber        = 998811;   // Magic Number EA

input group "--- Target Profit & Basket Loss (Dalam USC) ---"
input double   InpTargetProfitUSC    = 0.50;     // Target Profit Gabungan 5 Layer (0.50 USC = @0.10 USC/layer)
input double   InpBasketMaxLossUSC   = 12.0;     // HARD BASKET CUT LOSS TOTAL KESELURUHAN (-12 USC)

input group "--- Protection Area Pantulan (SnD & FVG M1) ---"
input int      InpLookbackCandles    = 25;       // Cek 25 Candle M1 untuk Area SnD
input double   InpMinFvgPips         = 8.0;      // Toleransi FVG (8 Pips)
input double   InpSafetyBufferPips   = 20.0;     // Jarak Aman dari Area Pantulan (20 Pips)

datetime lastTradeTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   Print("EA M1 Fast Scalper (5 Layer, Target >0.10 USC, Max Basket Loss -12 USC) Berhasil Aktif!");
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
   // 1. MONITOR BASKET PROFIT (>0.10 USC/Layer) & BASKET LOSS (-12 USC TOTAL)
   ManageBasketPL();

   // 2. Jeda 3 detik setelah close all agar tidak memicu over-entry
   if(TimeCurrent() - lastTradeTime < 3) return;

   // 3. Eksekusi 5 Layer Baru jika Posisi Sedang Kosong
   if(CountPositions() == 0)
     {
      ExecuteM1SmartEntry();
     }
  }

//+------------------------------------------------------------------+
//| KELOLA TOTAL BASKET PROFIT & BASKET CUT LOSS (-12 USC TOTAL)    |
//+------------------------------------------------------------------+
void ManageBasketPL()
  {
   if(CountPositions() == 0) return;

   double totalProfit = 0;

   // Hitung penjumlahan total PnL dari 5 layer yang sedang jalan
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

   // A. RUNNING PROFIT CUT ALL (Begitu total $\ge$ 0.50 USC / @0.10 USC per layer)
   if(totalProfit >= InpTargetProfitUSC)
     {
      CloseAllPositions();
      Print("TOTAL BASKET PROFIT TERCAPAI: ", totalProfit, " USC -> CUT ALL PROFIT!");
      lastTradeTime = TimeCurrent();
     }
   // B. HARD BASKET CUT LOSS (Begitu total akumulasi minus $\ge$ -12.0 USC)
   else if(totalProfit <= -InpBasketMaxLossUSC)
     {
      CloseAllPositions();
      Print("TOTAL KESELURUHAN MINUS MEMBENGKAK (", totalProfit, " USC) -> FAST BASKET CUT ALL (-12 USC)!");
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
//| FUNGSI ANALISIS ENTRY M1 & FILTER AREA PANTULAN (SnD & FVG)      |
//+------------------------------------------------------------------+
void ExecuteM1SmartEntry()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   if(CopyRates(_Symbol, _Period, 0, InpLookbackCandles, rates) < InpLookbackCandles) return;

   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // 1. CARI ZONA SUPPLY (ATAS) & DEMAND (BAWAH) 25 CANDLE TERAKHIR
   double supplyZone = rates[1].high;
   double demandZone = rates[1].low;

   for(int i = 1; i < InpLookbackCandles; i++)
     {
      if(rates[i].high > supplyZone) supplyZone = rates[i].high;
      if(rates[i].low < demandZone)   demandZone = rates[i].low;
     }

   // 2. DETEKSI FVG (Fair Value Gap)
   bool isBullishFVG = (rates[0].low - rates[2].high) / (10 * point) >= InpMinFvgPips;
   bool isBearishFVG = (rates[2].low - rates[0].high) / (10 * point) >= InpMinFvgPips;

   // 3. DETEKSI DIRECTIONAL MOMENTUM
   bool isCandleBull = rates[0].close > rates[0].open;
   bool isCandleBear = rates[0].close < rates[0].open;

   // 4. HITUNG JARAK AMAN DARI AREA PANTULAN (Anti Keseret)
   double distToSupply = (supplyZone - ask) / (10 * point); // Pips ke area atas (Supply)
   double distToDemand = (bid - demandZone) / (10 * point); // Pips ke area bawah (Demand)

   // --- LOGIKA FILTER ENTRY ---

   // SETUP BUY: (Candle Bullish / Bullish FVG) DAN Masih JAUH dari Area Supply Atas (> 20 Pips)
   if((isCandleBull || isBullishFVG) && distToSupply > InpSafetyBufferPips)
     {
      Print("Posisi Aman dari Supply Atas (Jarak: ", distToSupply, " Pips) -> Tembak 5 BUY!");
      for(int k = 0; k < InpLayerCount; k++)
        {
         trade.Buy(InpLotSize, _Symbol, ask, 0, 0, "M1 Smart Buy");
        }
      lastTradeTime = TimeCurrent();
     }
   // SETUP SELL: (Candle Bearish / Bearish FVG) DAN Masih JAUH dari Area Demand Bawah (> 20 Pips)
   else if((isCandleBear || isBearishFVG) && distToDemand > InpSafetyBufferPips)
     {
      Print("Posisi Aman dari Demand Bawah (Jarak: ", distToDemand, " Pips) -> Tembak 5 SELL!");
      for(int k = 0; k < InpLayerCount; k++)
        {
         trade.Sell(InpLotSize, _Symbol, bid, 0, 0, "M1 Smart Sell");
        }
      lastTradeTime = TimeCurrent();
     }
   else
     {
      // Terdeteksi Dekat Area Pantulan (SnD/FVG) -> BATALKAN ENTRY
      Print("Harga Dekat Area Pantulan SnD/FVG -> Entry Dibatalkan (Mencegah Trap/Keseret)");
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
