# Client price presentation

Core keeps profitability and settlement math in USDT, then converts the protected client amount into the requested display currency. A separate presentation policy shapes that exact converted amount into a predictable market-facing price.

```text
profitability-protected USDT amount
  -> exact FX conversion
  -> currency-aware upward presentation
  -> client-visible amount
```

Presentation never rounds down. It therefore cannot reduce the administrator floor, the executable-supply floor or the configured market margin.

Initial rules are deliberately explicit:

- USD, EUR, GBP and CHF round upward to `0.05`;
- CZK and PLN use whole commercial endings `9`, `19`, `49`, `99`;
- UAH and RUB round upward to `50`;
- HUF uses whole commercial endings `9`, `49`, `99`;
- currencies without a dedicated profile round upward to their `0.01` minor unit.

The policy affects buyer-facing localized amounts only. Broker supply normalization continues to use exact exchange-rate math and eight-decimal USDT precision. Adding or changing a currency profile is a core policy change and must include examples and regression tests.
