#!/usr/bin/python3
"""Experimental: the IMS state of the modem through libqmi (IMSA, IMS settings, PDC).

    diting-ims status [imsa-binding] [settings-binding]   a binding is none or a number; default 0
    diting-ims watch SECONDS [imsa-binding]
    diting-ims settings [enable]      the IMS settings of the modem
    diting-ims pdc [SECONDS]          the PDC indications for SECONDS, after asking for the selected configs
    diting-ims selected               the selected platform and software configurations, with their ids
    diting-ims pdc-load FILE          load a carrier config into the modem and activate it
    diting-ims pdc-select ID          select a configuration of the modem's list by its id (hex, 40 digits)

The list of configurations and their names is diting-pdc.py and diting-pdc-names.py
next to this file: libqmi gives neither in a usable form.
"""
import sys

import gi

gi.require_version("GLib", "2.0")
gi.require_version("Qmi", "1.0")
gi.require_version("Qrtr", "1.0")
from gi.repository import GLib, Qmi, Qrtr  # noqa: E402

T = 10
CHUNK = 1024
loop = GLib.MainLoop()
keep = {}       # objects that must outlive their callbacks
busy = []       # clients in use
holds = 0       # steps that will ask for another client
ok = True


def text(value):
    if isinstance(value, bytes):
        return value.decode("ascii", "replace") or "(empty)"
    return value.value_nick if hasattr(value, "value_nick") else value


def show(output, start="get_ims_", prefix="  "):
    """every field of a reply that starts with start; one the modem left out is named as such"""
    for name in sorted(n for n in dir(type(output)) if n.startswith(start)):
        try:
            value = text(getattr(output, name)())
        except GLib.Error:
            value = "(not in the reply)"
        print("%s%-48s %s" % (prefix, name[len(start):], value))


def fields(output, prefix="  "):
    """every field present in a reply"""
    for name in sorted(n for n in dir(type(output)) if n.startswith("get_") and n != "get_result"):
        try:
            value = text(getattr(output, name)())
        except (GLib.Error, TypeError):
            continue
        print("%s%-40s %s" % (prefix, name[4:], value))


def hold():
    global holds
    holds += 1


def check():
    if not busy and not holds:
        loop.quit()


def done(client):
    busy.remove(client)
    check()


def unhold():
    global holds
    holds -= 1
    check()


def fail(message):
    global ok
    ok = False
    print("error: %s" % message, file=sys.stderr)
    del busy[:]
    holds = 0
    loop.quit()


def result(output):
    output.get_result()


def nothing(good):
    pass


def ask(client, name, read, then, message=None):
    """one request: read() on the reply, then(True); after an error only then(False)"""

    def got(source, res, user_data=None):
        try:
            read(getattr(client, name + "_finish")(res))
        except GLib.Error as error:
            print("%s: %s" % (name.replace("_", " "), error.message))
            then(False)
            return
        then(True)

    getattr(client, name)(message, T, None, got, None)


def service(nick):
    for value in Qmi.Service.__enum_values__.values():
        if value.value_nick == nick:
            return value
    raise KeyError(nick)


def with_client(nick, use):
    """run use() with a client of the service, until it calls done()"""

    def allocated(source, res, user_data=None):
        try:
            client = keep["device"].allocate_client_finish(res)
        except GLib.Error as error:
            fail("couldn't create the %s client: %s" % (nick, error.message))
            return
        busy.append(client)
        use(client)

    keep["device"].allocate_client(service(nick), Qmi.CID_NONE, T, None, allocated, None)


def bind_message(short, word):
    """none → None; else the bind message of the service with that number"""
    if word == "none":
        return None
    message = getattr(Qmi, "Message%sBindInput" % short)()
    message.set_binding(int(word))
    return message


def bind(client, message, then):
    if message is None:
        then()
    else:
        ask(client, "bind", result, lambda good: then(), message)


def status(arguments):
    imsa_binding = bind_message("Imsa", arguments[0] if arguments else "0")
    settings_binding = bind_message("Ims", arguments[1] if len(arguments) > 1 else "0")
    hold()

    def settings():
        def use(client):
            def read(output):
                output.get_result()
                print("IMS settings:")
                show(output)

            def read_settings(good):
                done(client)
                unhold()
            bind(client, settings_binding, lambda: ask(client, "get_ims_services_enabled_setting", read, read_settings, None))
        with_client("ims", use)

    def registration(client):
        def read_services(output):
            output.get_result()
            print("IMSA services:")
            show(output)

        def read(output):
            output.get_result()
            print("IMSA registration:")
            show(output)

        def read_services_done(good):
            done(client)
            settings()
        bind(client, imsa_binding, lambda: ask(
            client, "get_ims_registration_status", read,
            lambda good: ask(client, "get_ims_services_status", read_services, read_services_done, None), None))

    with_client("imsa", registration)


def watch(seconds, arguments):
    message = Qmi.MessageImsaRegisterIndicationsInput()
    message.set_ims_registration_status_changed(True)
    message.set_ims_services_status_changed(True)

    def registration_changed(client, output, user_data=None):
        print("IMSA registration changed:")
        show(output)

    def services_changed(client, output, user_data=None):
        print("IMSA services changed:")
        show(output)

    def stop(client):
        print("done watching")
        done(client)
        return GLib.SOURCE_REMOVE

    def registered(client, good):
        print("watching for %d s" % seconds)
        GLib.timeout_add_seconds(seconds, stop, client)

    def start(client):
        client.connect("ims-registration-status-changed", registration_changed)
        client.connect("ims-services-status-changed", services_changed)
        ask(client, "register_indications", result, lambda good: registered(client, good), message)

    imsa_binding = bind_message("Imsa", arguments[0] if arguments else "0")
    with_client("imsa", lambda imsa: bind(imsa, imsa_binding, lambda: start(imsa)))


def register_message():
    """ask for every PDC indication"""
    message = Qmi.MessagePdcRegisterInput()
    message.set_enable_reporting(True)
    message.set_enable_refresh(True)
    return message


def pdc(arguments):
    seconds = int(arguments[0]) if arguments else 4
    kinds = list(Qmi.PdcConfigurationType.__enum_values__.values())

    def indicated(name):
        def handler(client, output, user_data=None):
            print("PDC indication %s:" % name)
            fields(output)
            if name == "list-configs":
                try:
                    print("  configs: %s" % ["%s %s %s" % (i.config_description, bytes(i.config_id).hex(), i.config_type)
                                            for i in output.get_configs()])
                except Exception as error:
                    print("  configs: not readable here (%s)" % type(error).__name__)
        return handler

    def selected(client, index):
        if index == len(kinds):
            GLib.timeout_add_seconds(seconds, lambda: (done(client), GLib.SOURCE_REMOVE)[1])
            return
        message = Qmi.MessagePdcGetSelectedConfigInput()
        message.set_config_type(kinds[index])
        print("selected config requested: %s" % kinds[index].value_nick)
        ask(client, "get_selected_config", result, lambda good: selected(client, index + 1), message)

    def start(client):
        for name in [i.get_name() for i in Qmi.ClientPdc.__info__.get_signals()]:
            client.connect(name, indicated(name))
        ask(client, "register", result, lambda good: selected(client, 0), register_message())

    with_client("pdc", start)


def protocol_error(code):
    try:
        return Qmi.ProtocolError(code).value_nick
    except (TypeError, ValueError):
        return str(code)


def pdc_load(arguments):
    """load the config file in chunks when the modem asks for them, then activate it"""
    import hashlib
    with open(arguments[0], "rb") as source:
        data = source.read()
    checksum = list(hashlib.sha1(data).digest())
    software = Qmi.PdcConfigurationType.SOFTWARE
    state = {"offset": 0, "token": 1, "stage": "loading"}

    def send_chunk(client):
        chunk = data[state["offset"]:state["offset"] + CHUNK]
        message = Qmi.MessagePdcLoadConfigInput()
        message.set_token(state["token"])
        message.set_config_chunk(software, checksum, len(data), list(chunk))
        number = state["offset"] // CHUNK + 1
        state["token"] += 1
        state["offset"] += len(chunk)
        if number == 1 or number % 20 == 0:
            print("chunk %d of %d sent" % (number, (len(data) + CHUNK - 1) // CHUNK))

        def sent(good):
            if not good:
                fail("the modem did not take chunk %d" % number)
        ask(client, "load_config", result, sent, message)

    def activate(client):
        message = Qmi.MessagePdcActivateConfigInput()
        message.set_config_type(software)
        message.set_token(state["token"])
        state["token"] += 1
        print("loaded; asking the modem to activate it (the modem restarts for that)")
        state["stage"] = "activating"

        def requested(good):
            if not good:
                print("no answer to the activation request: the modem is restarting")
                done(client)
        ask(client, "activate_config", result, requested, message)

    def loaded(client, output):
        code = int(text(output.get_indication_result()))
        if code:
            fail("the modem refused the config: %s (%d)" % (protocol_error(code), code))
            return
        try:
            if output.get_frame_reset():
                fail("the modem asked to reset the frame")
                return
        except GLib.Error:
            pass
        remaining = int(output.get_remaining_size())
        if remaining == 0:
            print("config loaded: %d bytes in %d chunks" % (len(data), (len(data) + CHUNK - 1) // CHUNK))
            activate(client)
        else:
            send_chunk(client)

    def indicated(name):
        def handler(client, output, user_data=None):
            print("PDC indication %s:" % name)
            fields(output)
            if name == "load-config" and state["stage"] == "loading":
                loaded(client, output)
            elif name == "activate-config" and state["stage"] == "activating":
                code = int(text(output.get_indication_result()))
                state["stage"] = "activated"
                print("activation %s" % ("requested" if code == 0 else "refused: %s (%d)" % (protocol_error(code), code)))
                GLib.timeout_add_seconds(3, lambda: (done(client), GLib.SOURCE_REMOVE)[1])
        return handler

    def start(client):
        for name in [i.get_name() for i in Qmi.ClientPdc.__info__.get_signals()]:
            client.connect(name, indicated(name))
        ask(client, "register", result, lambda good: send_chunk(client) if good else done(client), register_message())

    GLib.timeout_add_seconds(150, lambda: (fail("PDC load did not complete (stage %s)" % state["stage"]), GLib.SOURCE_REMOVE)[1])
    with_client("pdc", start)


def pdc_select(arguments):
    """select a config that is in the modem's list, by its 20 byte id in hex"""
    ident = list(bytes.fromhex(arguments[0].replace(":", "")))
    state = {"stage": "selecting"}

    def selected(client):
        """ask which config is selected now; the answer comes as an indication"""
        message = Qmi.MessagePdcGetSelectedConfigInput()
        message.set_config_type(Qmi.PdcConfigurationType.SOFTWARE)
        message.set_token(2)
        ask(client, "get_selected_config", result, nothing, message)
        GLib.timeout_add_seconds(4, lambda: (done(client), GLib.SOURCE_REMOVE)[1])

    def indicated(name):
        def handler(client, output, user_data=None):
            print("PDC indication %s:" % name)
            fields(output)
            if name == "set-selected-config" and state["stage"] == "selecting":
                code = int(text(output.get_indication_result()))
                state["stage"] = "selected" if code == 0 else "refused"
                print("selection %s" % ("requested" if code == 0 else "refused: %s (%d)" % (protocol_error(code), code)))
                GLib.timeout_add_seconds(2, lambda: (selected(client), GLib.SOURCE_REMOVE)[1])
        return handler

    def start(client):
        for name in [i.get_name() for i in Qmi.ClientPdc.__info__.get_signals()]:
            client.connect(name, indicated(name))
        message = Qmi.MessagePdcSetSelectedConfigInput()
        message.set_token(1)
        message.set_type_with_id_v2(Qmi.PdcConfigurationType.SOFTWARE, ident)

        def registered(good):
            if good:
                ask(client, "set_selected_config", result, nothing, message)
            else:
                done(client)
        ask(client, "register", result, registered, register_message())

    GLib.timeout_add_seconds(60, lambda: (fail("the selection did not complete (stage %s)" % state["stage"]), GLib.SOURCE_REMOVE)[1])
    with_client("pdc", start)


def shown(value):
    """config ids and versions are byte arrays"""
    if isinstance(value, (list, bytes, bytearray)):
        return bytes(value).hex()
    return text(value)


def pdc_selected(arguments):
    """the selected platform and software configurations, one request at a time: the
    answer comes as indications, which are told apart by what was asked for last"""
    state = {"phase": ""}

    def later(seconds, step):
        GLib.timeout_add_seconds(seconds, lambda: (step(), GLib.SOURCE_REMOVE)[1])

    def selected(client, kind, then):
        message = Qmi.MessagePdcGetSelectedConfigInput()
        message.set_config_type(kind)
        message.set_token(1)
        state["phase"] = "selected %s" % kind.value_nick
        print("selected %s configurations:" % kind.value_nick)
        ask(client, "get_selected_config", result, lambda good: None, message)
        later(3, then)

    def indicated(client, output, user_data=None):
        if not state["phase"].startswith("selected"):
            return
        for field in ("active_id", "pending_id"):
            try:
                print("  %s %s" % (field, shown(getattr(output, "get_" + field)())))
            except GLib.Error:
                pass                    # not in this indication
        print("  indication result %s (16 alone: none)" % shown(output.get_indication_result()))

    def start(client):
        client.connect("get-selected-config", indicated)
        ask(client, "register", result, lambda good: selected(
            client, Qmi.PdcConfigurationType.PLATFORM, lambda: selected(
                client, Qmi.PdcConfigurationType.SOFTWARE, lambda: done(client))), register_message())

    with_client("pdc", start)


def ims_settings(arguments):
    """the IMS settings as the modem has them; "enable" switches voice over LTE, SMS and XCAP on"""
    enable = bool(arguments) and arguments[0].startswith("enable")

    def use(client):
        def read(output):
            output.get_result()
            print("IMS settings:")
            show(output)

        def read_done(good):
            done(client)

        def enable_done(good):
            print("IMS %senabled" % ("" if good else "not "))
            ask(client, "get_ims_services_enabled_setting", read, read_done, None)

        def enabling():
            message = Qmi.MessageImsSetImsServicesEnabledSettingInput()
            setters = ["set_ims_voice_over_lte_enable", "set_ims_sms_service_enable", "set_ims_ut_service_enable"]
            if arguments[0] == "enable-all":
                setters += ["set_ims_service_enabled", "set_ims_autoconfig_enabled"]
            for setter in setters:
                try:
                    getattr(message, setter)(True)
                except GLib.Error as error:
                    print("  %s: %s" % (setter, error.message))
            ask(client, "set_ims_services_enabled_setting", result, enable_done, message)

        def bound(good):
            if good and enable:
                enabling()
            else:
                ask(client, "get_ims_services_enabled_setting", read, read_done, None)
        ask(client, "bind", result, bound, bind_message("Ims", "0"))
    with_client("ims", use)


def watch_command(arguments):
    watch(int(arguments[0]) if arguments else 30, arguments[1:])


def opened(source, res, user_data=None):
    try:
        keep["device"].open_finish(res)
    except GLib.Error as error:
        fail("couldn't open the device: %s" % error.message)
        return
    COMMAND[0](ARGUMENTS[0])


def created(source, res, user_data=None):
    try:
        keep["device"] = Qmi.Device.new_finish(res)
    except GLib.Error as error:
        fail("couldn't create the device: %s" % error.message)
        return
    keep["device"].open(Qmi.DeviceOpenFlags.VERSION_INFO | Qmi.DeviceOpenFlags.EXPECT_INDICATIONS, 15, None, opened, None)


def bus_ready(source, res, user_data=None):
    try:
        keep["bus"] = Qrtr.Bus.new_finish(res)
    except GLib.Error as error:
        fail("couldn't access the QRTR bus: %s" % error.message)
        return
    for candidate in keep["bus"].peek_nodes() or []:
        if any(info.get_service() == service("nas") for info in candidate.peek_service_info_list() or []):
            Qmi.Device.new_from_node(candidate, None, created, None)
            return
    fail("no node with the NAS service in the QRTR bus")


def timed_out():
    fail("the modem did not answer in time")
    return GLib.SOURCE_REMOVE


COMMANDS = {"status": status, "watch": watch_command, "pdc": pdc, "selected": pdc_selected, "pdc-load": pdc_load, "pdc-select": pdc_select, "settings": ims_settings}
COMMAND = [status]
ARGUMENTS = [[]]


def main(arguments):
    if arguments and arguments[0] not in COMMANDS:
        print(__doc__, file=sys.stderr)
        return 2
    COMMAND[0] = COMMANDS[arguments[0]] if arguments else status
    ARGUMENTS[0] = arguments[1:]
    if not Qrtr.get_node_for_uri("qrtr://0/", 0):
        print("error: no QRTR node 0", file=sys.stderr)
        return 1
    GLib.timeout_add_seconds(200, timed_out)
    Qrtr.Bus.new(1000, None, bus_ready, None)
    loop.run()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
