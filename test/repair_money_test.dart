import 'package:flutter_test/flutter_test.dart';

import 'package:ultrasound_inventory/features/data/data.dart';

void main() {
  test('repairMoneyText joins the amount and the person', () {
    expect(
      repairMoneyText({'money_received': 5000, 'money_received_by': 'Ahmed'}),
      '5000 — received by Ahmed',
    );
  });

  test('repairMoneyText shows the amount alone without a person', () {
    expect(repairMoneyText({'money_received': 2500.5}), '2500.5');
    expect(
      repairMoneyText({'money_received': 2500.5, 'money_received_by': '   '}),
      '2500.5',
    );
  });

  test('repairMoneyText is empty for zero or missing amounts', () {
    expect(repairMoneyText(<String, dynamic>{}), '');
    expect(repairMoneyText({'money_received': null}), '');
    expect(
      repairMoneyText({'money_received': 0, 'money_received_by': 'Usman'}),
      '',
    );
    expect(repairMoneyText({'money_received': 'abc'}), '');
  });

  test('repairMoneyText keeps decimal amounts', () {
    expect(
      repairMoneyText({'money_received': 1234.25, 'money_received_by': 'Irshad'}),
      '1234.25 — received by Irshad',
    );
  });
}
