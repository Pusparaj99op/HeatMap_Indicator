//+------------------------------------------------------------------+
//| BookmapHeatmap.mq5 — Bookmap-Style Order Flow Indicator          |
//| Tick-level liquidity heatmap, delta, volume bubbles, signals      |
//+------------------------------------------------------------------+
#property copyright   "HeatMap Indicator"
#property version     "1.00"
#property description "Bookmap-style order flow visualization using tick data"
#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots   2
#property indicator_type1   DRAW_HISTOGRAM
#property indicator_color1  clrLimeGreen
#property indicator_width1  2
#property indicator_label1  "Smoothed Delta"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrDodgerBlue
#property indicator_width2  2
#property indicator_label2  "Cumulative Delta"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "═══ Core Settings ═══"
input int    InpTickBufferSize     = 5000;    // Tick buffer capacity
input double InpVolNormFactor      = 1.0;     // Volume normalization factor
input int    InpDeltaSmoothPeriod  = 14;      // Delta EMA smoothing period
input double InpPriceLevelStep     = 0;       // Price bucket size (0=auto)
input int    InpMaxHistoryBars     = 200;     // Max visual history bars
input int    InpMaxObjects         = 2000;    // Object pool limit

input group "═══ Heatmap Settings ═══"
input double InpHeatmapIntensity   = 1.5;     // Heatmap intensity scale
input int    InpHeatmapRows        = 20;      // Price levels in heatmap
input int    InpHeatmapAlpha       = 85;      // Heatmap opacity (0-100)

input group "═══ Bubble Settings ═══"
input double InpBubbleSizeMultiplier = 1.0;   // Bubble size multiplier
input double InpBubbleMinRelVol    = 0.5;     // Min relative vol to show

input group "═══ Signal Settings ═══"
input double InpAbsRangeATR        = 0.3;     // Absorption: max range/ATR
input double InpAbsVolMult         = 2.0;     // Absorption: min vol mult
input double InpBrkVolMult         = 1.8;     // Breakout: min vol mult
input int    InpBrkLookback        = 20;      // Breakout lookback bars
input int    InpDivLookback        = 14;      // Divergence lookback bars

input group "═══ Module Toggles ═══"
input bool   InpEnableHeatmap      = true;    // Enable heatmap
input bool   InpEnableDelta        = true;    // Enable delta
input bool   InpEnableBubbles      = true;    // Enable volume bubbles
input bool   InpEnableSignals      = true;    // Enable signals

//+------------------------------------------------------------------+
//| DATA STRUCTURES                                                   |
//+------------------------------------------------------------------+
struct TickRecord
{
   double   price;
   double   volume;
   datetime time;
   uint     flags;
};

struct PriceLevel
{
   double price;
   double totalVolume;
   double buyVolume;
   double sellVolume;
   double delta;
   int    tickCount;
   int    touchCount;
};

struct DOMSnapshot
{
   datetime time;
   double   bidPrices[20];
   double   bidVolumes[20];
   double   askPrices[20];
   double   askVolumes[20];
   int      bidCount;
   int      askCount;
};

//+------------------------------------------------------------------+
//| CTickEngine — Circular buffer for tick storage & aggregation      |
//+------------------------------------------------------------------+
class CTickEngine
{
private:
   TickRecord  m_buffer[];
   int         m_head;
   int         m_count;
   int         m_capacity;
   double      m_priceStep;
   PriceLevel  m_levels[];
   int         m_levelCount;
   double      m_avgVolume;
   int         m_avgWindow;

public:
   void Init(int capacity, double priceStep)
   {
      m_capacity = capacity;
      m_head = 0;
      m_count = 0;
      m_priceStep = priceStep > 0 ? priceStep :
                    SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(m_priceStep <= 0) m_priceStep = 0.01;
      ArrayResize(m_buffer, m_capacity);
      m_levelCount = 0;
      m_avgVolume = 0;
      m_avgWindow = 200;
   }

   void AddTick(const MqlTick &tick)
   {
      m_buffer[m_head].price  = tick.last > 0 ? tick.last : tick.bid;
      m_buffer[m_head].volume = (double)tick.volume;
      m_buffer[m_head].time   = tick.time;
      m_buffer[m_head].flags  = tick.flags;
      m_head = (m_head + 1) % m_capacity;
      if(m_count < m_capacity) m_count++;
      // Update rolling average volume
      int window = MathMin(m_avgWindow, m_count);
      if(window > 0)
      {
         double sum = 0;
         for(int i = 0; i < window; i++)
         {
            int idx = (m_head - 1 - i + m_capacity) % m_capacity;
            sum += m_buffer[idx].volume;
         }
         m_avgVolume = sum / window;
      }
   }

   bool GetTick(int offset, TickRecord &out)
   {
      if(offset < 0 || offset >= m_count) return false;
      int idx = (m_head - 1 - offset + m_capacity) % m_capacity;
      out = m_buffer[idx];
      return true;
   }

   double GetAverageVolume() { return m_avgVolume > 0 ? m_avgVolume : 1.0; }
   int    GetCount()         { return m_count; }
   double GetPriceStep()     { return m_priceStep; }

   double BucketPrice(double price)
   {
      return MathRound(price / m_priceStep) * m_priceStep;
   }

   // Aggregate recent ticks into price levels
   void BuildPriceLevels(int window)
   {
      int count = MathMin(window, m_count);
      // Use temporary map via sorted array
      double tempPrices[];
      double tempVolumes[];
      double tempBuyVol[];
      double tempSellVol[];
      int    tempTicks[];
      int    tempSize = 0;
      ArrayResize(tempPrices, count);
      ArrayResize(tempVolumes, count);
      ArrayResize(tempBuyVol, count);
      ArrayResize(tempSellVol, count);
      ArrayResize(tempTicks, count);

      for(int i = 0; i < count; i++)
      {
         int idx = (m_head - 1 - i + m_capacity) % m_capacity;
         double bp = BucketPrice(m_buffer[idx].price);
         double vol = m_buffer[idx].volume;
         bool isBuy = (m_buffer[idx].flags & TICK_FLAG_BUY) != 0;

         // Find existing level
         int found = -1;
         for(int j = 0; j < tempSize; j++)
         {
            if(MathAbs(tempPrices[j] - bp) < m_priceStep * 0.1)
            { found = j; break; }
         }
         if(found >= 0)
         {
            tempVolumes[found] += vol;
            if(isBuy) tempBuyVol[found] += vol;
            else       tempSellVol[found] += vol;
            tempTicks[found]++;
         }
         else if(tempSize < count)
         {
            tempPrices[tempSize] = bp;
            tempVolumes[tempSize] = vol;
            tempBuyVol[tempSize] = isBuy ? vol : 0;
            tempSellVol[tempSize] = isBuy ? 0 : vol;
            tempTicks[tempSize] = 1;
            tempSize++;
         }
      }

      // Copy to m_levels
      m_levelCount = tempSize;
      ArrayResize(m_levels, m_levelCount);
      for(int i = 0; i < m_levelCount; i++)
      {
         m_levels[i].price       = tempPrices[i];
         m_levels[i].totalVolume = tempVolumes[i];
         m_levels[i].buyVolume   = tempBuyVol[i];
         m_levels[i].sellVolume  = tempSellVol[i];
         m_levels[i].delta       = tempBuyVol[i] - tempSellVol[i];
         m_levels[i].tickCount   = tempTicks[i];
         m_levels[i].touchCount  = tempTicks[i]; // simplified
      }
   }

   int GetLevelCount() { return m_levelCount; }

   bool GetLevel(int index, PriceLevel &out)
   {
      if(index < 0 || index >= m_levelCount) return false;
      out = m_levels[index];
      return true;
   }

   double GetMaxVolume()
   {
      double maxVol = 0;
      for(int i = 0; i < m_levelCount; i++)
         if(m_levels[i].totalVolume > maxVol)
            maxVol = m_levels[i].totalVolume;
      return maxVol > 0 ? maxVol : 1.0;
   }
};

//+------------------------------------------------------------------+
//| CDeltaEngine — Tick classification and delta tracking             |
//+------------------------------------------------------------------+
class CDeltaEngine
{
private:
   double   m_cumDelta;
   double   m_smoothedDelta;
   double   m_prevPrice;
   double   m_emaMult;
   int      m_emaPeriod;
   bool     m_initialized;
   // Per-level delta tracking
   double   m_levelPrices[];
   double   m_levelDeltas[];
   int      m_levelCount;
   int      m_maxLevels;
   double   m_priceStep;

public:
   void Init(int emaPeriod, double priceStep)
   {
      m_cumDelta = 0;
      m_smoothedDelta = 0;
      m_prevPrice = 0;
      m_emaPeriod = emaPeriod;
      m_emaMult = 2.0 / (emaPeriod + 1.0);
      m_initialized = false;
      m_maxLevels = 500;
      m_levelCount = 0;
      m_priceStep = priceStep;
      ArrayResize(m_levelPrices, m_maxLevels);
      ArrayResize(m_levelDeltas, m_maxLevels);
   }

   // Returns tick delta (+vol for buy, -vol for sell)
   double ProcessTick(const MqlTick &tick)
   {
      double price = tick.last > 0 ? tick.last : tick.bid;
      double vol = (double)tick.volume;
      if(vol <= 0) vol = 1;
      double tickDelta = 0;

      // Prefer native flags
      if((tick.flags & TICK_FLAG_BUY) != 0)
         tickDelta = vol;
      else if((tick.flags & TICK_FLAG_SELL) != 0)
         tickDelta = -vol;
      else if(m_prevPrice > 0)
      {
         // Tick rule fallback
         if(price > m_prevPrice)      tickDelta = vol;
         else if(price < m_prevPrice) tickDelta = -vol;
         // price == prev → inherit previous direction (simplified: 0)
      }

      m_prevPrice = price;
      m_cumDelta += tickDelta;

      // EMA smoothing
      if(!m_initialized)
      { m_smoothedDelta = m_cumDelta; m_initialized = true; }
      else
         m_smoothedDelta = m_cumDelta * m_emaMult + m_smoothedDelta * (1.0 - m_emaMult);

      // Update per-level delta
      UpdateLevelDelta(price, tickDelta);
      return tickDelta;
   }

   void UpdateLevelDelta(double price, double delta)
   {
      double bp = MathRound(price / m_priceStep) * m_priceStep;
      for(int i = 0; i < m_levelCount; i++)
      {
         if(MathAbs(m_levelPrices[i] - bp) < m_priceStep * 0.1)
         { m_levelDeltas[i] += delta; return; }
      }
      if(m_levelCount < m_maxLevels)
      {
         m_levelPrices[m_levelCount] = bp;
         m_levelDeltas[m_levelCount] = delta;
         m_levelCount++;
      }
   }

   double GetCumulativeDelta()  { return m_cumDelta; }
   double GetSmoothedDelta()    { return m_smoothedDelta; }

   double GetLevelDelta(double price)
   {
      double bp = MathRound(price / m_priceStep) * m_priceStep;
      for(int i = 0; i < m_levelCount; i++)
         if(MathAbs(m_levelPrices[i] - bp) < m_priceStep * 0.1)
            return m_levelDeltas[i];
      return 0;
   }

   void ResetLevels()
   {
      m_levelCount = 0;
      ArrayInitialize(m_levelDeltas, 0);
   }
};

//+------------------------------------------------------------------+
//| CHeatmapEngine — DOM capture and liquidity approximation          |
//+------------------------------------------------------------------+
class CHeatmapEngine
{
private:
   DOMSnapshot m_snapshots[];
   int         m_snapHead;
   int         m_snapCount;
   int         m_snapCapacity;
   bool        m_hasDom;
   double      m_intensityMap[];
   double      m_intensityPrices[];
   int         m_intensityCount;
   int         m_maxIntensity;
   double      m_priceStep;

public:
   void Init(int capacity, double priceStep)
   {
      m_snapCapacity = capacity;
      m_snapHead = 0;
      m_snapCount = 0;
      m_hasDom = false;
      m_maxIntensity = 200;
      m_intensityCount = 0;
      m_priceStep = priceStep;
      ArrayResize(m_snapshots, m_snapCapacity);
      ArrayResize(m_intensityMap, m_maxIntensity);
      ArrayResize(m_intensityPrices, m_maxIntensity);
      ArrayInitialize(m_intensityMap, 0);
   }

   bool HasDOM() { return m_hasDom; }

   void OnBookUpdate(MqlBookInfo &book[], int bookSize)
   {
      m_hasDom = true;
      DOMSnapshot snap;
      snap.time = TimeCurrent();
      snap.bidCount = 0;
      snap.askCount = 0;
      for(int i = 0; i < bookSize && i < 40; i++)
      {
         if(book[i].type == BOOK_TYPE_SELL && snap.askCount < 20)
         {
            snap.askPrices[snap.askCount]  = book[i].price;
            snap.askVolumes[snap.askCount] = (double)book[i].volume;
            snap.askCount++;
         }
         else if(book[i].type == BOOK_TYPE_BUY && snap.bidCount < 20)
         {
            snap.bidPrices[snap.bidCount]  = book[i].price;
            snap.bidVolumes[snap.bidCount] = (double)book[i].volume;
            snap.bidCount++;
         }
      }
      m_snapshots[m_snapHead] = snap;
      m_snapHead = (m_snapHead + 1) % m_snapCapacity;
      if(m_snapCount < m_snapCapacity) m_snapCount++;
      RebuildIntensityFromDOM();
   }

   void RebuildIntensityFromDOM()
   {
      m_intensityCount = 0;
      ArrayInitialize(m_intensityMap, 0);
      int latest = (m_snapHead - 1 + m_snapCapacity) % m_snapCapacity;
      DOMSnapshot snap = m_snapshots[latest];
      double maxVol = 1.0;
      // Find max volume for normalization
      for(int i = 0; i < snap.bidCount; i++)
         if(snap.bidVolumes[i] > maxVol) maxVol = snap.bidVolumes[i];
      for(int i = 0; i < snap.askCount; i++)
         if(snap.askVolumes[i] > maxVol) maxVol = snap.askVolumes[i];
      // Build intensity
      for(int i = 0; i < snap.bidCount && m_intensityCount < m_maxIntensity; i++)
      {
         m_intensityPrices[m_intensityCount] = snap.bidPrices[i];
         m_intensityMap[m_intensityCount] = snap.bidVolumes[i] / maxVol;
         m_intensityCount++;
      }
      for(int i = 0; i < snap.askCount && m_intensityCount < m_maxIntensity; i++)
      {
         m_intensityPrices[m_intensityCount] = snap.askPrices[i];
         m_intensityMap[m_intensityCount] = snap.askVolumes[i] / maxVol;
         m_intensityCount++;
      }
   }

   // Fallback: approximate liquidity from tick volume clusters
   void ApproximateFromLevels(PriceLevel &levels[], int count, double maxVol)
   {
      if(m_hasDom) return; // DOM takes priority
      m_intensityCount = 0;
      for(int i = 0; i < count && m_intensityCount < m_maxIntensity; i++)
      {
         m_intensityPrices[m_intensityCount] = levels[i].price;
         m_intensityMap[m_intensityCount] = levels[i].totalVolume / (maxVol > 0 ? maxVol : 1.0);
         m_intensityCount++;
      }
   }

   double GetIntensity(double price)
   {
      double bp = MathRound(price / m_priceStep) * m_priceStep;
      for(int i = 0; i < m_intensityCount; i++)
         if(MathAbs(m_intensityPrices[i] - bp) < m_priceStep * 0.5)
            return m_intensityMap[i];
      return 0;
   }

   int GetIntensityCount()                          { return m_intensityCount; }
   double GetIntensityPrice(int i)                  { return i < m_intensityCount ? m_intensityPrices[i] : 0; }
   double GetIntensityValue(int i)                  { return i < m_intensityCount ? m_intensityMap[i] : 0; }
};

//+------------------------------------------------------------------+
//| CRenderEngine — Object pool management and chart rendering        |
//+------------------------------------------------------------------+
class CRenderEngine
{
private:
   string  m_prefix;
   int     m_maxObjects;
   int     m_heatIdx;
   int     m_bubbleIdx;
   int     m_signalIdx;
   int     m_totalCreated;

   // Color gradient: Blue → Cyan → Yellow → Orange → Red
   color HeatColor(double intensity)
   {
      int r, g, b;
      if(intensity < 0.25)
      {
         double t = intensity / 0.25;
         r = 0; g = (int)(t * 220); b = (int)(255 - t * 55);
      }
      else if(intensity < 0.5)
      {
         double t = (intensity - 0.25) / 0.25;
         r = 0; g = (int)(220 + t * 35); b = (int)(200 * (1.0 - t));
      }
      else if(intensity < 0.75)
      {
         double t = (intensity - 0.5) / 0.25;
         r = (int)(t * 255); g = 255; b = 0;
      }
      else
      {
         double t = (intensity - 0.75) / 0.25;
         r = 255; g = (int)(255 * (1.0 - t)); b = 0;
      }
      r = MathMax(0, MathMin(255, r));
      g = MathMax(0, MathMin(255, g));
      b = MathMax(0, MathMin(255, b));
      return (color)((b << 16) | (g << 8) | r);
   }

   string ObjName(string type, int idx)
   {
      return m_prefix + type + IntegerToString(idx);
   }

public:
   void Init(int maxObjects)
   {
      m_prefix = "BM_";
      m_maxObjects = maxObjects;
      m_heatIdx = 0;
      m_bubbleIdx = 0;
      m_signalIdx = 0;
      m_totalCreated = 0;
   }

   void ResetIndices()
   {
      m_heatIdx = 0;
      m_bubbleIdx = 0;
      m_signalIdx = 0;
   }

   // Draw heatmap rectangle at a price level
   void DrawHeatRect(double priceTop, double priceBot, datetime timeLeft,
                     datetime timeRight, double intensity, int alpha)
   {
      if(m_heatIdx >= m_maxObjects / 3) return;
      string name = ObjName("H", m_heatIdx++);
      color clr = HeatColor(MathMin(1.0, intensity));
      if(ObjectFind(0, name) < 0)
      {
         ObjectCreate(0, name, OBJ_RECTANGLE, 0,
                      timeLeft, priceTop, timeRight, priceBot);
         m_totalCreated++;
      }
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 0);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      // Set transparency via OBJPROP_FILL and color alpha
      int transp = 100 - alpha;
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 0, priceTop);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 1, priceBot);
      ObjectSetInteger(0, name, OBJPROP_TIME, 0, timeLeft);
      ObjectSetInteger(0, name, OBJPROP_TIME, 1, timeRight);
   }

   // Draw volume bubble (arrow circle)
   void DrawBubble(datetime time, double price, double relVol,
                   bool isBuy, double sizeMultiplier)
   {
      if(m_bubbleIdx >= m_maxObjects / 3) return;
      string name = ObjName("B", m_bubbleIdx++);
      color clr = isBuy ? (color)0x0076E600 : (color)0x004417FF; // Green / Red
      int width = (int)MathMax(1, MathMin(5, relVol * sizeMultiplier));
      if(ObjectFind(0, name) < 0)
      {
         ObjectCreate(0, name, OBJ_ARROW, 0, time, price);
         m_totalCreated++;
      }
      ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 159); // Filled circle
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 0, price);
      ObjectSetInteger(0, name, OBJPROP_TIME, 0, time);
   }

   // Draw signal marker
   void DrawSignal(datetime time, double price, string text,
                   color clr, int arrowCode)
   {
      if(m_signalIdx >= m_maxObjects / 3) return;
      string name = ObjName("S", m_signalIdx++);
      if(ObjectFind(0, name) < 0)
      {
         ObjectCreate(0, name, OBJ_ARROW, 0, time, price);
         m_totalCreated++;
      }
      ObjectSetInteger(0, name, OBJPROP_ARROWCODE, arrowCode);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 0, price);
      ObjectSetInteger(0, name, OBJPROP_TIME, 0, time);
      // Add text label nearby
      string lblName = name + "L";
      if(ObjectFind(0, lblName) < 0)
      {
         ObjectCreate(0, lblName, OBJ_TEXT, 0, time, price);
         m_totalCreated++;
      }
      ObjectSetString(0, lblName, OBJPROP_TEXT, text);
      ObjectSetInteger(0, lblName, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 7);
      ObjectSetDouble(0, lblName, OBJPROP_PRICE, 0, price);
      ObjectSetInteger(0, lblName, OBJPROP_TIME, 0, time);
   }

   // Draw info dashboard
   void DrawDashboard(double barDelta, double cumDelta, double smoothDelta,
                      double relVol, double buyRatio, bool hasDom)
   {
      string dashPrefix = m_prefix + "DASH_";
      int x = 10, y = 30, rowH = 18, colW = 110;
      // Background
      string bgName = dashPrefix + "BG";
      if(ObjectFind(0, bgName) < 0)
         ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, x - 5);
      ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, y - 5);
      ObjectSetInteger(0, bgName, OBJPROP_XSIZE, colW * 2 + 10);
      ObjectSetInteger(0, bgName, OBJPROP_YSIZE, rowH * 7 + 10);
      ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, 0x001E1E1E);
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_COLOR, 0x00333333);
      ObjectSetInteger(0, bgName, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, bgName, OBJPROP_BACK, false);
      ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bgName, OBJPROP_HIDDEN, true);

      string labels[]  = {"Bar Delta", "Cum. Delta", "Smooth Δ", "Rel. Volume", "Buy Ratio", "DOM"};
      string values[6];
      color  vColors[6];
      values[0] = DoubleToString(barDelta, 0);
      vColors[0] = barDelta >= 0 ? clrLime : clrRed;
      values[1] = DoubleToString(cumDelta, 0);
      vColors[1] = cumDelta >= 0 ? clrLime : clrRed;
      values[2] = DoubleToString(smoothDelta, 0);
      vColors[2] = smoothDelta >= 0 ? clrLime : clrRed;
      values[3] = DoubleToString(relVol, 2) + "x";
      vColors[3] = relVol >= 2.0 ? clrOrange : clrSilver;
      values[4] = DoubleToString(buyRatio * 100, 0) + "%";
      vColors[4] = buyRatio >= 0.5 ? clrLime : clrRed;
      values[5] = hasDom ? "Active" : "Approx";
      vColors[5] = hasDom ? clrLime : clrGold;

      for(int i = 0; i < 6; i++)
      {
         string lName = dashPrefix + "L" + IntegerToString(i);
         string vName = dashPrefix + "V" + IntegerToString(i);
         if(ObjectFind(0, lName) < 0)
            ObjectCreate(0, lName, OBJ_LABEL, 0, 0, 0);
         ObjectSetString(0, lName, OBJPROP_TEXT, labels[i]);
         ObjectSetInteger(0, lName, OBJPROP_COLOR, clrSilver);
         ObjectSetInteger(0, lName, OBJPROP_FONTSIZE, 8);
         ObjectSetInteger(0, lName, OBJPROP_XDISTANCE, x + colW * 2 - 5);
         ObjectSetInteger(0, lName, OBJPROP_YDISTANCE, y + i * rowH);
         ObjectSetInteger(0, lName, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
         ObjectSetInteger(0, lName, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, lName, OBJPROP_HIDDEN, true);

         if(ObjectFind(0, vName) < 0)
            ObjectCreate(0, vName, OBJ_LABEL, 0, 0, 0);
         ObjectSetString(0, vName, OBJPROP_TEXT, values[i]);
         ObjectSetInteger(0, vName, OBJPROP_COLOR, vColors[i]);
         ObjectSetInteger(0, vName, OBJPROP_FONTSIZE, 8);
         ObjectSetInteger(0, vName, OBJPROP_XDISTANCE, x);
         ObjectSetInteger(0, vName, OBJPROP_YDISTANCE, y + i * rowH);
         ObjectSetInteger(0, vName, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
         ObjectSetInteger(0, vName, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, vName, OBJPROP_HIDDEN, true);
      }
   }

   // Cleanup stale objects beyond current indices
   void CleanupStale()
   {
      // Remove old heat rects
      for(int i = m_heatIdx; i < m_heatIdx + 50; i++)
      {
         string name = ObjName("H", i);
         if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
         else break;
      }
      for(int i = m_bubbleIdx; i < m_bubbleIdx + 50; i++)
      {
         string name = ObjName("B", i);
         if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
         else break;
      }
      for(int i = m_signalIdx; i < m_signalIdx + 50; i++)
      {
         string name = ObjName("S", i);
         if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
         string lbl = name + "L";
         if(ObjectFind(0, lbl) >= 0) ObjectDelete(0, lbl);
         else break;
      }
   }

   void Cleanup()
   {
      ObjectsDeleteAll(0, m_prefix);
      m_totalCreated = 0;
   }

   int GetTotalCreated() { return m_totalCreated; }
};

//+------------------------------------------------------------------+
//| GLOBAL ENGINE INSTANCES                                           |
//+------------------------------------------------------------------+
CTickEngine    g_tickEngine;
CDeltaEngine   g_deltaEngine;
CHeatmapEngine g_heatmapEngine;
CRenderEngine  g_renderEngine;

// Indicator buffers
double g_smoothDeltaBuf[];
double g_cumDeltaBuf[];

// State
double g_priceStep;
int    g_tickCounter;
double g_lastBarDelta;
double g_lastRelVol;
double g_lastBuyRatio;
double g_atr14[];
double g_highestHigh[];
double g_lowestLow[];

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   // Determine price step
   g_priceStep = InpPriceLevelStep > 0 ? InpPriceLevelStep :
                 SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(g_priceStep <= 0) g_priceStep = 0.01;

   // Init engines
   g_tickEngine.Init(InpTickBufferSize, g_priceStep);
   g_deltaEngine.Init(InpDeltaSmoothPeriod, g_priceStep);
   g_heatmapEngine.Init(100, g_priceStep);
   g_renderEngine.Init(InpMaxObjects);

   // Setup indicator buffers
   SetIndexBuffer(0, g_smoothDeltaBuf, INDICATOR_DATA);
   SetIndexBuffer(1, g_cumDeltaBuf, INDICATOR_DATA);
   PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_HISTOGRAM);
   PlotIndexSetInteger(1, PLOT_DRAW_TYPE, DRAW_LINE);
   PlotIndexSetString(0, PLOT_LABEL, "Smoothed Delta");
   PlotIndexSetString(1, PLOT_LABEL, "Cumulative Delta");

   // Subscribe to market depth
   MarketBookAdd(_Symbol);

   g_tickCounter = 0;
   g_lastBarDelta = 0;
   g_lastRelVol = 0;
   g_lastBuyRatio = 0.5;

   IndicatorSetString(INDICATOR_SHORTNAME, "BM-Heatmap");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   MarketBookRelease(_Symbol);
   g_renderEngine.Cleanup();
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| OnBookEvent — DOM data capture                                    |
//+------------------------------------------------------------------+
void OnBookEvent(const string &symbol)
{
   if(symbol != _Symbol || !InpEnableHeatmap) return;
   MqlBookInfo book[];
   if(MarketBookGet(_Symbol, book))
   {
      g_heatmapEngine.OnBookUpdate(book, ArraySize(book));
   }
}

//+------------------------------------------------------------------+
//| OnTick — Main tick processing pipeline                            |
//+------------------------------------------------------------------+
void OnTick()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   // Feed tick to engines
   g_tickEngine.AddTick(tick);
   double tickDelta = g_deltaEngine.ProcessTick(tick);

   g_tickCounter++;
   double price = tick.last > 0 ? tick.last : tick.bid;
   double vol = (double)tick.volume;
   double avgVol = g_tickEngine.GetAverageVolume();
   double relVol = avgVol > 0 ? vol / avgVol : 0;
   bool isBuy = tickDelta > 0;

   g_lastBarDelta = tickDelta;
   g_lastRelVol = relVol;
   g_lastBuyRatio = isBuy ? MathMin(1.0, 0.5 + relVol * 0.1) :
                            MathMax(0.0, 0.5 - relVol * 0.1);

   // Volume bubble rendering (per-tick)
   if(InpEnableBubbles && relVol >= InpBubbleMinRelVol)
   {
      g_renderEngine.DrawBubble(tick.time, price, relVol,
                                isBuy, InpBubbleSizeMultiplier);
   }

   // Throttled operations (every 50 ticks)
   if(g_tickCounter % 50 == 0)
   {
      // Rebuild price levels for heatmap
      g_tickEngine.BuildPriceLevels(MathMin(2000, InpTickBufferSize));

      // Update heatmap
      if(InpEnableHeatmap)
         RenderHeatmap();

      // Check signals
      if(InpEnableSignals)
         CheckSignals(tick.time, price, relVol);

      // Dashboard
      g_renderEngine.DrawDashboard(
         g_lastBarDelta,
         g_deltaEngine.GetCumulativeDelta(),
         g_deltaEngine.GetSmoothedDelta(),
         g_lastRelVol,
         g_lastBuyRatio,
         g_heatmapEngine.HasDOM()
      );

      // Cleanup stale objects
      g_renderEngine.CleanupStale();
      ChartRedraw(0);
   }
}

//+------------------------------------------------------------------+
//| RenderHeatmap — Draw heatmap rectangles from engine data          |
//+------------------------------------------------------------------+
void RenderHeatmap()
{
   g_renderEngine.ResetIndices();
   int levelCount = g_tickEngine.GetLevelCount();
   double maxVol = g_tickEngine.GetMaxVolume();

   // If no DOM, approximate from tick volume
   if(!g_heatmapEngine.HasDOM() && levelCount > 0)
   {
      PriceLevel tempLevels[];
      ArrayResize(tempLevels, levelCount);
      for(int i = 0; i < levelCount; i++)
         g_tickEngine.GetLevel(i, tempLevels[i]);
      g_heatmapEngine.ApproximateFromLevels(tempLevels, levelCount, maxVol);
   }

   // Render intensity levels
   int intensityCount = g_heatmapEngine.GetIntensityCount();
   datetime now = TimeCurrent();
   datetime barDuration = PeriodSeconds(PERIOD_CURRENT);
   if(barDuration <= 0) barDuration = 60;
   datetime timeRight = now + barDuration * 5;

   double halfStep = g_priceStep * 0.5;
   for(int i = 0; i < intensityCount; i++)
   {
      double p = g_heatmapEngine.GetIntensityPrice(i);
      double intensity = g_heatmapEngine.GetIntensityValue(i) * InpHeatmapIntensity;
      if(intensity < 0.1) continue; // Skip very low intensity

      g_renderEngine.DrawHeatRect(
         p + halfStep, p - halfStep,
         now - barDuration * InpMaxHistoryBars, timeRight,
         intensity, InpHeatmapAlpha
      );
   }
}

//+------------------------------------------------------------------+
//| CheckSignals — Absorption, Breakout, Delta Divergence             |
//+------------------------------------------------------------------+
void CheckSignals(datetime time, double price, double relVol)
{
   int bars = iBars(_Symbol, PERIOD_CURRENT);
   if(bars < InpBrkLookback + 2) return;

   // Get ATR for normalization
   double atr = 0;
   int atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
   if(atrHandle != INVALID_HANDLE)
   {
      double atrBuf[];
      if(CopyBuffer(atrHandle, 0, 0, 1, atrBuf) > 0)
         atr = atrBuf[0];
      IndicatorRelease(atrHandle);
   }
   if(atr <= 0) return;

   // Current bar data
   double curHigh = iHigh(_Symbol, PERIOD_CURRENT, 0);
   double curLow  = iLow(_Symbol, PERIOD_CURRENT, 0);
   double curClose = iClose(_Symbol, PERIOD_CURRENT, 0);
   double curRange = curHigh - curLow;

   // ── ABSORPTION DETECTION ──
   // High volume + tight range = absorption
   if(curRange < atr * InpAbsRangeATR && relVol > InpAbsVolMult)
   {
      double closePos = curRange > 0 ? (curClose - curLow) / curRange : 0.5;
      if(closePos > 0.6) // Bullish absorption
      {
         g_renderEngine.DrawSignal(time, curLow - atr * 0.5,
                                   "ABS", clrLime, 4); // Diamond up
      }
      else if(closePos < 0.4) // Bearish absorption
      {
         g_renderEngine.DrawSignal(time, curHigh + atr * 0.5,
                                   "ABS", clrRed, 4); // Diamond down
      }
   }

   // ── BREAKOUT DETECTION ──
   // Price exceeds lookback high/low with volume expansion
   double prevHigh = curHigh, prevLow = curLow;
   for(int i = 1; i <= InpBrkLookback; i++)
   {
      double h = iHigh(_Symbol, PERIOD_CURRENT, i);
      double l = iLow(_Symbol, PERIOD_CURRENT, i);
      if(h > prevHigh) prevHigh = h;
      if(l < prevLow)  prevLow = l;
   }

   if(curClose > prevHigh && relVol > InpBrkVolMult)
   {
      g_renderEngine.DrawSignal(time, curLow - atr * 0.8,
                                "BRK▲", clrLime, 233); // Triangle up
   }
   else if(curClose < prevLow && relVol > InpBrkVolMult)
   {
      g_renderEngine.DrawSignal(time, curHigh + atr * 0.8,
                                "BRK▼", clrRed, 234); // Triangle down
   }

   // ── DELTA DIVERGENCE ──
   double cumDelta = g_deltaEngine.GetCumulativeDelta();
   // Simple divergence: price at high but delta weakening
   static double s_maxPrice = 0, s_maxDelta = 0;
   static double s_minPrice = DBL_MAX, s_minDelta = DBL_MAX;
   static int    s_divCounter = 0;
   s_divCounter++;

   if(curClose > s_maxPrice)
   { s_maxPrice = curClose; s_maxDelta = cumDelta; }
   if(curClose < s_minPrice)
   { s_minPrice = curClose; s_minDelta = cumDelta; }

   // Reset tracking periodically
   if(s_divCounter > InpDivLookback * 50)
   {
      s_maxPrice = curClose; s_maxDelta = cumDelta;
      s_minPrice = curClose; s_minDelta = cumDelta;
      s_divCounter = 0;
   }

   // Bearish divergence: price at new high, delta below previous high
   if(curClose >= s_maxPrice * 0.999 && cumDelta < s_maxDelta * 0.95
      && relVol > 1.0 && s_divCounter > InpDivLookback)
   {
      g_renderEngine.DrawSignal(time, curHigh + atr * 1.0,
                                "DIV▼", clrOrange, 251); // X cross
   }
   // Bullish divergence: price at new low, delta above previous low
   if(curClose <= s_minPrice * 1.001 && cumDelta > s_minDelta * 0.95
      && relVol > 1.0 && s_divCounter > InpDivLookback)
   {
      g_renderEngine.DrawSignal(time, curLow - atr * 1.0,
                                "DIV▲", clrCyan, 251); // X cross
   }
}

//+------------------------------------------------------------------+
//| OnCalculate — Update indicator buffers                            |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   if(!InpEnableDelta) return rates_total;

   // Fill buffers for the current bar
   int idx = rates_total - 1;
   if(idx >= 0)
   {
      g_smoothDeltaBuf[idx] = g_deltaEngine.GetSmoothedDelta();
      g_cumDeltaBuf[idx]    = g_deltaEngine.GetCumulativeDelta();
   }

   return rates_total;
}

//+------------------------------------------------------------------+
//| OnChartEvent — Handle chart interactions                          |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
   // Redraw dashboard on chart resize
   if(id == CHARTEVENT_CHART_CHANGE)
   {
      g_renderEngine.DrawDashboard(
         g_lastBarDelta,
         g_deltaEngine.GetCumulativeDelta(),
         g_deltaEngine.GetSmoothedDelta(),
         g_lastRelVol,
         g_lastBuyRatio,
         g_heatmapEngine.HasDOM()
      );
   }
}
//+------------------------------------------------------------------+
