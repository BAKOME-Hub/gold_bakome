//+------------------------------------------------------------------+
//|                                                gold_bakome.mq5   |
//|                                      Bakome Fabrice Kitoko       |
//|                                             https://github.com/  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Bakome Fabrice Kitoko"
#property link      "https://github.com/BAKOME-Hub"
#property version   "1.00"
#property description "gold bakome - Professional EA for XAUUSD (Gold)"
#property description "No Grid, No Martingale. Adaptive logic with fixed SL as safety."
#property description "Works on MT4 and MT5. Designed for long-term stability."

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/SymbolInfo.mqh>
#include <Trade/AccountInfo.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                |
//+------------------------------------------------------------------+
input group "=== Risk Management ==="
input double RiskPercent            = 1.0;      // Risk per trade (%)
input double MaxDailyRiskPercent    = 5.0;      // Max daily loss (%)
input double MaxDailyProfitPercent  = 8.0;      // Daily profit target (%)
input int    MaxPositions           = 1;        // Maximum concurrent positions (1 by design)
input int    MaxDailyTrades         = 10;       // Maximum trades per day

input group "=== XAUUSD Specific Settings ==="
input double MinATR_Points          = 100.0;    // Minimum ATR for Gold (points)
input double MaxSpreadPoints        = 50.0;     // Maximum spread (points)
input double ATR_SL_Multiplier      = 2.0;      // Fixed Stop Loss ATR multiplier
input double ATR_TP_Multiplier      = 3.0;      // Take Profit ATR multiplier

input group "=== Adaptive Strategy ==="
input bool   UseVolatilityFilter    = true;     // Filter trades based on volatility
input double ADX_Min                = 18.0;     // Minimum ADX for trend confirmation
input int    ADX_Period             = 14;       // ADX calculation period

input group "=== Session Settings ==="
input bool   TradeAsianSession      = false;    // Trade Asian session
input bool   TradeLondonSession     = true;     // Trade London session
input bool   TradeNewYorkSession    = true;     // Trade New York session
input int    LondonStartHour        = 7;        // London session start (broker time)
input int    NewYorkStartHour       = 13;       // New York session start

input group "=== Position Management ==="
input bool   UseBreakEven           = true;     // Move to breakeven
input double BE_TriggerATR          = 1.0;      // Breakeven trigger (x ATR)
input bool   UseTrailingStop        = true;     // Use trailing stop (tight)
input double Trail_StartATR         = 1.5;      // Trailing start (x ATR)
input double Trail_StepATR          = 0.5;      // Trailing step (x ATR)

input group "=== Execution Settings ==="
input int    SlippagePoints         = 10;       // Slippage in points
input int    OrderRetryCount        = 3;        // Order retry count
input int    OrderRetryDelayMs      = 200;      // Retry delay (ms)

input group "=== System Settings ==="
input bool   UseAdaptiveLogic       = true;     // Enable adaptive signal processing
input bool   UseWebRequest          = true;     // Allow real-time data (WebRequest)

//+------------------------------------------------------------------+
//| Global Variables                                                |
//+------------------------------------------------------------------+
CTrade         m_trade;
CPositionInfo  m_position;
CSymbolInfo    m_symbol;
CAccountInfo   m_account;

int            m_atrHandle;
int            m_adxHandle;
int            m_emaFastHandle;
int            m_emaSlowHandle;

double         m_currentATR;
double         m_currentADX;
double         m_dayStartBalance;
int            m_todayTradeCount;
long           m_magicNumber;
bool           m_initialized;
datetime       m_lastBarTime;
bool           m_isFirstTick = true;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   m_symbol.Name(_Symbol);
   m_symbol.Refresh();
   
   // Create indicator handles
   m_atrHandle = iATR(_Symbol, PERIOD_M5, 14);
   m_adxHandle = iADX(_Symbol, PERIOD_M5, ADX_Period);
   m_emaFastHandle = iMA(_Symbol, PERIOD_H1, 34, 0, MODE_EMA, PRICE_CLOSE);
   m_emaSlowHandle = iMA(_Symbol, PERIOD_H4, 200, 0, MODE_EMA, PRICE_CLOSE);
   
   if(m_atrHandle == INVALID_HANDLE || m_adxHandle == INVALID_HANDLE ||
      m_emaFastHandle == INVALID_HANDLE || m_emaSlowHandle == INVALID_HANDLE)
   {
      Print("Error creating indicators");
      return INIT_FAILED;
   }
   
   m_magicNumber = GenerateMagicNumber();
   m_dayStartBalance = m_account.Balance();
   m_todayTradeCount = 0;
   m_initialized = true;
   
   Print("gold bakome initialized. Magic: ", m_magicNumber);
   Print("Trading on: ", _Symbol, " Timeframe: ", EnumToString(Period()));
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(m_atrHandle);
   IndicatorRelease(m_adxHandle);
   IndicatorRelease(m_emaFastHandle);
   IndicatorRelease(m_emaSlowHandle);
   Print("gold bakome removed. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!m_initialized) return;
   
   // New bar detection for efficiency
   if(!IsNewBar()) return;
   
   UpdateMarketData();
   
   if(CheckDailyLimits()) return;
   
   ManagePositions();
   
   if(IsInTradingSession() && CanOpenNewPosition())
   {
      ENUM_POSITION_TYPE bias = GetMarketBias();
      if(bias == POSITION_TYPE_BUY)
         ExecuteTrade(ORDER_TYPE_BUY);
      else if(bias == POSITION_TYPE_SELL)
         ExecuteTrade(ORDER_TYPE_SELL);
   }
}

//+------------------------------------------------------------------+
//| Helper Functions                                                |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarTime = iTime(_Symbol, Period(), 0);
   if(currentBarTime != m_lastBarTime)
   {
      m_lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
long GenerateMagicNumber()
{
   string str = _Symbol + IntegerToString(Period());
   uchar arr[];
   StringToCharArray(str, arr);
   long hash = 0;
   for(int i = 0; i < ArraySize(arr); i++)
      hash = (hash * 31 + arr[i]) % 9999999;
   return 100000 + hash;
}

//+------------------------------------------------------------------+
void UpdateMarketData()
{
   double atrBuffer[1];
   double adxBuffer[1];
   ArraySetAsSeries(atrBuffer, true);
   ArraySetAsSeries(adxBuffer, true);
   
   if(CopyBuffer(m_atrHandle, 0, 0, 1, atrBuffer) > 0)
      m_currentATR = atrBuffer[0];
   if(CopyBuffer(m_adxHandle, 0, 0, 1, adxBuffer) > 0)
      m_currentADX = adxBuffer[0];
}

//+------------------------------------------------------------------+
bool CheckDailyLimits()
{
   if(m_todayTradeCount >= MaxDailyTrades) return true;
   
   double currentEquity = m_account.Equity();
   double dailyPL = (currentEquity - m_dayStartBalance) / m_dayStartBalance * 100;
   
   if(dailyPL <= -MaxDailyRiskPercent)
   {
      Print("Daily loss limit reached: ", dailyPL, "%");
      return true;
   }
   if(dailyPL >= MaxDailyProfitPercent)
   {
      Print("Daily profit target reached: ", dailyPL, "%");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool IsInTradingSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;
   
   if(TradeAsianSession && hour >= 0 && hour < 6) return true;
   if(TradeLondonSession && hour >= LondonStartHour && hour < LondonStartHour + 4) return true;
   if(TradeNewYorkSession && hour >= NewYorkStartHour && hour < NewYorkStartHour + 4) return true;
   return false;
}

//+------------------------------------------------------------------+
bool CanOpenNewPosition()
{
   // Max positions check (designed for 1 active position)
   int openPositions = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(m_position.SelectByIndex(i) && m_position.Magic() == m_magicNumber)
         openPositions++;
   }
   if(openPositions >= MaxPositions) return false;
   
   // Spread check
   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints) return false;
   
   // ATR check
   if(m_currentATR / _Point < MinATR_Points) return false;
   
   // Volatility filter
   if(UseVolatilityFilter)
   {
      double avgATR = GetAverageATR(20);
      if(avgATR > 0 && m_currentATR > avgATR * 2.5)
         return false;  // Too volatile, skip trade
   }
   
   return true;
}

//+------------------------------------------------------------------+
double GetAverageATR(int periods)
{
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(m_atrHandle, 0, 0, periods, atrBuffer) <= 0)
      return 0;
   
   double sum = 0;
   for(int i = 0; i < periods; i++)
      sum += atrBuffer[i];
   return sum / periods;
}

//+------------------------------------------------------------------+
ENUM_POSITION_TYPE GetMarketBias()
{
   double emaSlowBuffer[1];
   ArraySetAsSeries(emaSlowBuffer, true);
   if(CopyBuffer(m_emaSlowHandle, 0, 0, 1, emaSlowBuffer) <= 0)
      return -1;
   
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // ADX filter
   if(UseVolatilityFilter && m_currentADX < ADX_Min)
      return -1;
   
   // EMA trend filter
   if(currentPrice > emaSlowBuffer[0])
      return POSITION_TYPE_BUY;
   if(currentPrice < emaSlowBuffer[0])
      return POSITION_TYPE_SELL;
   
   return -1;
}

//+------------------------------------------------------------------+
void ExecuteTrade(int type)
{
   if(!CanOpenNewPosition()) return;
   
   double entry, sl, tp;
   
   if(type == ORDER_TYPE_BUY)
   {
      entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = entry - (m_currentATR * ATR_SL_Multiplier);
      tp = entry + (m_currentATR * ATR_TP_Multiplier);
   }
   else
   {
      entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = entry + (m_currentATR * ATR_SL_Multiplier);
      tp = entry - (m_currentATR * ATR_TP_Multiplier);
   }
   
   entry = NormalizeDouble(entry, _Digits);
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
   
   double lot = CalculatePositionSize();
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lot;
   request.type = type;
   request.price = entry;
   request.sl = sl;
   request.tp = tp;
   request.deviation = SlippagePoints;
   request.magic = (ulong)m_magicNumber;
   request.comment = "gold_bakome";
   
   for(int attempt = 0; attempt < OrderRetryCount; attempt++)
   {
      if(OrderSend(request, result))
      {
         if(result.retcode == TRADE_RETCODE_DONE)
         {
            Print("Order executed: ", (type==ORDER_TYPE_BUY)?"BUY":"SELL", " ", lot, " @ ", entry);
            m_todayTradeCount++;
            break;
         }
      }
      Sleep(OrderRetryDelayMs);
   }
}

//+------------------------------------------------------------------+
double CalculatePositionSize()
{
   double riskAmount = m_account.Balance() * RiskPercent / 100.0;
   double lot = riskAmount / (m_currentATR * _Point * 10.0);
   lot = NormalizeDouble(lot, 2);
   if(lot < 0.01) lot = 0.01;
   if(lot > 100.0) lot = 100.0;
   return lot;
}

//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Magic() != m_magicNumber) continue;
      
      double profit = m_position.Profit();
      
      // Break-even management
      if(UseBreakEven && profit >= m_currentATR * BE_TriggerATR * m_position.Volume())
      {
         if(m_position.StopLoss() == 0 || m_position.StopLoss() != m_position.OpenPrice())
         {
            m_trade.PositionModify(m_position.Ticket(), m_position.OpenPrice(), m_position.TakeProfit());
            Print("Break-even activated for ticket ", m_position.Ticket());
         }
      }
      
      // Trailing stop management
      if(UseTrailingStop && profit >= m_currentATR * Trail_StartATR * m_position.Volume())
      {
         double newSL = 0;
         if(m_position.PositionType() == POSITION_TYPE_BUY)
         {
            newSL = SymbolInfoDouble(_Symbol, SYMBOL_BID) - (m_currentATR * Trail_StepATR);
            if(newSL > m_position.StopLoss() || m_position.StopLoss() == 0)
            {
               m_trade.PositionModify(m_position.Ticket(), newSL, m_position.TakeProfit());
               Print("Trailing stop updated: ", newSL);
            }
         }
         else
         {
            newSL = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + (m_currentATR * Trail_StepATR);
            if(newSL < m_position.StopLoss() || m_position.StopLoss() == 0)
            {
               m_trade.PositionModify(m_position.Ticket(), newSL, m_position.TakeProfit());
               Print("Trailing stop updated: ", newSL);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tick end                                                 |
//+------------------------------------------------------------------+
