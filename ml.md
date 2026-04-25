# ml.md – Machine Learning in Lyx

## 1. Übersicht

`std.ml` bietet Machine Learning Grundfunktionen für Lyx. Die Bibliothek unterstützt:
- Lineare Regression (Vorhersage kontinuierlicher Werte) - **1 oder 2 Datenpunkte**
- Logistische Regression (Binäre Klassifikation) - **1 oder 2 Datenpunkte**
- k-Nearest Neighbors (k-NN)
- k-Means Clustering
- Statistische Metriken
- Normalisierung

**Für fortgeschrittene ML mit großen Datasets:** Siehe `data.core` Modul (Pandas-ähnlich)

---

## 2. Schnellstart

```lyx
import std.io;
import std.ml;

pub fn main(): int64 {
  // Lineare Regression: y = 2x + 1
  LinearRegressionInit();
  LinearRegressionFit2(1.0, 2.0, 3.0, 5.0, 0.1, 100);
  
  var pred: f64 := LinearRegressionPredict(5.0);
  PrintFloat(pred);  // ~11
  
  return 0;
}
```

---

## 3. Lineare Regression

### 3.1 Verwendung

```lyx
// 1. Initialisieren
LinearRegressionInit();

// 2. Trainieren mit 2 Datenpunkten
//    Fit2(x0, x1, y0, y1, learning_rate, epochs)
LinearRegressionFit2(1.0, 3.0, 2.0, 7.0, 0.1, 100);

// 3. Vorhersagen
var y: f64 := LinearRegressionPredict(5.0);

// 4. Modell-Parameter abrufen
var w: f64 := LinearRegressionWeight();  // Steigung
var b: f64 := LinearRegressionBias();  // Bias
var loss: f64 := LinearRegressionLoss();  // MSE Loss
```

### 3.2 Beispiel: Hauspreis-Vorhersage

```lyx
import std.io;
import std.ml;

pub fn main(): int64 {
  // Trainingsdaten: qm -> preis (tausend Euro)
  // 50qm -> 100, 100qm -> 200
  LinearRegressionInit();
  LinearRegressionFit2(50.0, 100.0, 100.0, 200.0, 0.1, 100);
  
  // Vorhersage für 75qm
  var preis: f64 := LinearRegressionPredict(75.0);
  PrintStr("Preis für 75qm: ");
  PrintFloat(preis);  // ~150
  
  return 0;
}
```

---

## 4. Logistische Regression

### 4.1 Verwendung

```lyx
// 1. Initialisieren
LogisticRegressionInit();

// 2. Trainieren
LogisticRegressionFit2(x0, x1, y0, y1, learning_rate, epochs);
// y-Werte: 0.0 oder 1.0 (binär)

// 3. Vorhersage
var prob: f64 := LogisticRegressionPredictProb(5.0);  // Wahrscheinlichkeit
var klasse: int64 := LogisticRegressionPredict(5.0);  // 0 oder 1
```

### 4.2 Beispiel: Spam-Erkennung

```lyx
import std.io;
import std.ml;

pub fn main(): int64 {
  // Trainingsdaten: wörter -> spam (0/1)
  // 10 wörter -> 0, 100 wörter -> 1
  LogisticRegressionInit();
  LogisticRegressionFit2(10.0, 100.0, 0.0, 1.0, 0.1, 100);
  
  // Test: 50 wörter
  var ist_spam: int64 := LogisticRegressionPredict(50.0);
  if (ist_spam == 1) {
    PrintStr("Ist Spam!\n");
  } else {
    PrintStr("Kein Spam.\n");
  }
  
  return 0;
}
```

---

## 5. k-Nearest Neighbors (k-NN)

### 5.1 Verwendung

```lyx
// 1. Initialisieren mit Trainingsdaten
// KNNInit2(k, x0, x1, y0, y1)
KNNInit2(1, 1.0, 3.0, 0.0, 1.0);  // k=1, (x=1,y=0), (x=3,y=1)

// 2. Vorhersage - k nearest neighbors
var klasse: int64 := KNNPredict(2.5);
```

### 5.2 Beispiel

```lyx
import std.io;
import std.ml;

pub fn main(): int64 {
  // Daten: x = alter, y = kauft (0=nein, 1=ja)
  // jugendlich (20) -> kauft nicht, erwachsener (40) -> kauft
  KNNInit2(1, 20.0, 40.0, 0.0, 1.0);
  
  //Test: 30 jähriger
  var result: int64 := KNNPredict(30.0);
  PrintStr("30 jähriger: ");
  if (result == 1) { PrintStr("kauft\n"); }
  else { PrintStr("kauft nicht\n"); }
  
  return 0;
}
```

---

## 6. k-Means Clustering

### 6.1 Verwendung

```lyx
// 1. Initialisieren mit Start-Centroiden
KMeansInit2(0.0, 10.0);

// 2. Fitten
KMeansFit2(2.0, 8.0, 10);  // datenpunkte, iterationen

// 3. Cluster vorhersagen
var cluster: int64 := KMeansPredict(5.0);

// 4. Centroiden abrufen
var c0: f64 := KMeansCentroid0();
var c1: f64 := KMeansCentroid1();
```

---

## 7. Statistische Metriken

### 7.1 Mean, Variance, StdDev

```lyx
var mean: f64 := Mean2(4.0, 6.0);      // 5.0
var varianz: f64 := Variance2(4.0, 6.0);  // 1.0
var stddev: f64 := StdDev2(4.0, 6.0);    // 1.0
```

### 7.2 Loss-Metriken

```lyx
var mse: f64 := MSE2(3.0, 5.0, 3.1, 4.9);   // Mean Squared Error
var mae: f64 := MAE2(3.0, 5.0, 3.1, 4.9);   // Mean Absolute Error
var r2: f64 := R2Score2(3.0, 5.0, 3.0, 5.0); // R² Score (1.0 = perfekt)
```

---

## 8. Normalisierung

### 8.1 Min-Max Normalisierung

Skaliert Werte auf [0, 1]:

```lyx
var normiert: f64 := MinMaxNorm(5.0, 0.0, 10.0);  // 0.5
var original: f64 := MinMaxDenorm(0.5, 0.0, 10.0); // 5.0
```

### 8.2 Z-Score Standardisierung

Skaliert auf Mittelwert=0, StdDev=1:

```lyx
var z: f64 := ZScoreNorm(5.0, 2.0, 2.0);  // 1.5
```

---

## 9. Fortgeschritten: data.core für große Datasets

Für Datasets mit >2 Punkten verwende `data.core`:

```lyx
import data.core;

pub fn main(): int64 {
  var df := DataFrameNew();
  DataFrameAddColumnFloat64(df, "alter");
  DataFrameAddColumnFloat64(df, "kauft");
  
  // Daten hinzufügen
  var i: int64 := 0;
  while (i < 100) {
    DataFrameAppendRow(df);
    DataFrameSetFloat64(df, "alter", i, i as f64);
    var label: f64 := 0.0;
    if (i > 50) { label := 1.0; }
    DataFrameSetFloat64(df, "kauft", i, label);
    i := i + 1;
  }
  
  // Trainieren
  LinearRegressionFitDataFrame(df, "alter", "kauft");
  
  return 0;
}
```

### 9.1 data.core Funktionen

| Funktion | Beschreibung |
|----------|---------------|
| `DataFrameNew()` | Neues DataFrame erstellen |
| `DataFrameAddColumnFloat64(df, name)` | Float64-Spalte hinzufügen |
| `DataFrameAppendRow(df)` | Neue Zeile hinzufügen |
| `DataFrameSetFloat64(df, col, row, val)` | Wert setzen |
| `DataFrameGetFloat64(df, col, row)` | Wert lesen |
| `DataFrameFilter(df, col, op, value)` | Zeilen filtern |
| `DataFrameGroupBy(df, col)` | Gruppieren |

---

## 10. Best Practices

### 10.1 Training

```lyx
// Starten mit small learning rate
var lr: f64 := 0.1;

// Mehr iterationen für bessere konvergenz
LinearRegressionFit2(x0, x1, y0, y1, lr, 1000);
```

### 10.2 Daten-Split

```lyx
// Train/Test Split (50/50)
var split: int64 := TrainTestSplit(index);
if (split == 0) {
  // Trainingsdaten
} else {
  // Testdaten
}
```

### 10.3 Normalisierung

**Immer normalisieren** vor dem Training:

```lyx
// Daten normalisieren vor training
var x_norm: f64 := MinMaxNorm(x, min, max);
```

### 10.4 Model Evaluation

```lyx
// R² Score prüfen ( > 0.9 ist gut)
var r2: f64 := R2Score2(y_true0, y_true1, y_pred0, y_pred1);
if (r2 > 0.9) {
  PrintStr("Gutes Modell!\n");
}
```

---

## 11. FAQ

### Q: Warum nur 2 Datenpunkte?

Das Basis-Modul `std.ml` unterstützt 2 Punkte für einfache Demos und Tests. Für echte ML mit vielen Datenpunkten:

1. **Kompromiss:** 2 Punkte reichen für lineare Probleme
2. **Fortgeschritten:** `data.core` für größere Datasets
3. **Limitierung:** Keine Array-Parameter in Lyx (noch nicht unterstützt)

### Q: Wie wähle ich learning rate?

- **Zu hoch:** Modell konvergiert nicht
- **Zu niedrig:** Training dauert lange
- **Empfehlung:** 0.001 bis 0.1 starten

### Q: Wann logistische vs lineare Regression?

- **Linear:** Kontinuierlicher Wert (Preis, Temperatur)
- **Logistisch:** Binär (Ja/Nein, Spam/Nicht Spam)

---

## 12. Limitierungen

- Nur 2 Datenpunkte pro Training
- Keine Mehr-Klassen Klassifikation
- Keine echten Arrays (kommt bald)
- Keine Cross-Validation (manuell)

**Für Production:** `data.core` + externe Libraries

---

## 13. Siehe auch

- `data.core` - Pandas-ähnliches DataFrame Modul
- `std.stats` - Statistics Funktionen
- `test_ml_*.lyx` - Beispiele im Repository