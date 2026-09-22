//+------------------------------------------------------------------+
//|                                               EA_SMC_XAUUSD.mq5  |
//|                          Advanced Price Action, FVG, OB, & HTF   |
//+------------------------------------------------------------------+
#property copyright "Gemini AI - Institutional Logic"
#property version   "2.01"

#include <Trade\Trade.mqh>
CTrade trade;

//--- Input Parameters
input double   InpLotSize           = 0.02;      // Lot Size
input int      InpMagicNumber       = 999888;    // Magic Number
input int      InpSlippage          = 3;         // Slippage

//--- Kill Zones (Waktu Broker - Sesuaikan dengan GMT Broker)
input int      AsiaStart            = 0;
input int      AsiaEnd              = 6;
input int      LondonStart          = 8;
input int      LondonEnd            = 12;
input int      NYStart              = 13;
input int      NYEnd                = 18;

//--- Setup Parameters (PERBAIKAN ERROR: Menggunakan ENUM_TIMEFRAMES)
input ENUM_TIMEFRAMES HTF_Period    = PERIOD_H1; // Higher Timeframe Bias
input ENUM_TIMEFRAMES LTF_Period    = PERIOD_M5; // Lower Timeframe Entry

int handle_ema200_HTF;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   
   // Menggunakan EMA 200 di HTF sebagai penentu Bias (Discount/Premium zone)
   handle_ema200_HTF = iMA(_Symbol, HTF_Period, 200, 0, MODE_EMA, PRICE_CLOSE);
   
   if(handle_ema200_HTF == INVALID_HANDLE)
     {
      Print("Gagal memuat HTF Bias Indicator!");
      return(INIT_FAILED);
     }
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Hanya eksekusi pada awal candle baru LTF (M5)
   static datetime last_time = 0;
   datetime current_time = iTime(_Symbol, LTF_Period, 0);
   if(current_time == last_time) return;
   
   // Hapus pending order yang kadaluarsa/tidak tersentuh terlalu lama
   ManagePendingOrders();
   
   // Cek apakah ada posisi terbuka, jika ada biarkan (1 posisi at a time)
   if(PositionsTotal() > 0) return; 

   last_time = current_time;

   //--- 1. CEK KILL ZONES (SESSION TIMINGS)
   MqlDateTime time_struct;
   TimeToStruct(TimeCurrent(), time_struct);
   int h = time_struct.hour;
   
   bool isAsia   = (h >= AsiaStart && h <= AsiaEnd);
   bool isLondon = (h >= LondonStart && h <= LondonEnd);
   bool isNY     = (h >= NYStart && h <= NYEnd);
   
   // Jika di luar Kill Zone, jangan cari setup (Hindari chop/sideways)
   if(!isAsia && !isLondon && !isNY) return;

   //--- 2. HTF BIAS (Arah Market Utama)
   double htf_ema[1];
   CopyBuffer(handle_ema200_HTF, 0, 0, 1, htf_ema);
   double htf_close = iClose(_Symbol, HTF_Period, 1);
   
   bool isHTFBullish = (htf_close > htf_ema[0]); // Harga di atas EMA 200 H1 = Cari Buy (Discount Zone)
   bool isHTFBearish = (htf_close < htf_ema[0]); // Harga di bawah EMA 200 H1 = Cari Sell (Premium Zone)

   //--- 3. DETEKSI FVG (FAIR VALUE GAP) & DISPLACEMENT DI LTF (M5)
   // Pattern 3 Candle: Candle 1, Candle 2 (Impulsive/Displacement), Candle 3
   // Index 1 = Candle yang baru close, Index 2 = Candle Impulsive, Index 3 = Candle sebelumnya
   
   double high1 = iHigh(_Symbol, LTF_Period, 1);
   double low1  = iLow(_Symbol, LTF_Period, 1);
   
   double high3 = iHigh(_Symbol, LTF_Period, 3);
   double low3  = iLow(_Symbol, LTF_Period, 3);
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   // SETUP BUY: HTF Bullish + LTF Bullish FVG (MSS terjadi meninggalkan FVG)
   if(isHTFBullish && OrdersTotal() == 0)
     {
      // Logika Bullish FVG: Low candle 1 tidak menyentuh High candle 3
      if(low1 > high3)
        {
         double fvg_top = low1;
         double fvg_bottom = high3;
         double fvg_size = fvg_top - fvg_bottom;
         
         // Pastikan gap cukup besar (menandakan Displacement/Institusi masuk)
         if(fvg_size > 50 * point) 
           {
            // Cari Order Block (Candle bearish terakhir sebelum pam)
            double ob_low = iLow(_Symbol, LTF_Period, 3); // Simplifikasi OB di candle 3
            
            double entry_price = fvg_top; // Entry saat harga retrace ke ujung atas FVG (OTE)
            double sl_price = ob_low - (20 * point); // SL di bawah Order Block + buffer
            double tp_price = entry_price + ((entry_price - sl_price) * 2); // Risk Reward 1:2
            
            // Pasang Buy Limit
            trade.BuyLimit(InpLotSize, entry_price, _Symbol, sl_price, tp_price, ORDER_TIME_GTC, 0, "SMC Buy Limit FVG");
            Print("Bullish FVG Terdeteksi! Buy Limit dipasang.");
           }
        }
     }
     
   // SETUP SELL: HTF Bearish + LTF Bearish FVG
   if(isHTFBearish && OrdersTotal() == 0)
     {
      // Logika Bearish FVG: High candle 1 tidak menyentuh Low candle 3
      if(high1 < low3)
        {
         double fvg_bottom = high1;
         double fvg_top = low3;
         double fvg_size = fvg_top - fvg_bottom;
         
         if(fvg_size > 50 * point) // Displacement Check
           {
            // Cari Order Block (Candle bullish terakhir sebelum dump)
            double ob_high = iHigh(_Symbol, LTF_Period, 3);
            
            double entry_price = fvg_bottom; // Entry di ujung bawah FVG
            double sl_price = ob_high + (20 * point); // SL di atas Order Block + buffer
            double tp_price = entry_price - ((sl_price - entry_price) * 2); // RR 1:2
            
            // Pasang Sell Limit
            trade.SellLimit(InpLotSize, entry_price, _Symbol, sl_price, tp_price, ORDER_TIME_GTC, 0, "SMC Sell Limit FVG");
            Print("Bearish FVG Terdeteksi! Sell Limit dipasang.");
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Fungsi Menghapus Limit Order Lama (Jika harga tidak retrace)     |
//+------------------------------------------------------------------+
void ManagePendingOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
        {
         // Logika ICT: Jika limit order ditinggalkan dan market sudah bergerak terlalu jauh (Invalidation)
         // Di sini kita simplifikasi: Hapus order jika dibiarkan > 20 candle tanpa ter-trigger
         
         // PERBAIKAN WARNING: Casting tipe data ke datetime
         datetime setup_time = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
         
         if(TimeCurrent() - setup_time > (20 * PeriodSeconds(LTF_Period)))
           {
            trade.OrderDelete(ticket);
            Print("Pending Order Expired, Dihapus karena harga tidak retrace.");
           }
        }
     }
  }
//+------------------------------------------------------------------+
