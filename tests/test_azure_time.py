"""Azure returns run times with 0 to 7 decimal places; the post-deploy test must parse them all."""

import datetime as dt

from send_sample_alert import azure_time


def test_any_number_of_decimal_places():
    utc = dt.timezone.utc
    assert azure_time("2026-11-26T21:04:18Z") == dt.datetime(2026, 11, 26, 21, 4, 18, tzinfo=utc)
    assert azure_time("2026-11-26T21:04:18.2452Z").microsecond == 245200
    assert azure_time("2026-11-26T21:04:18.1234567Z").microsecond == 123456
