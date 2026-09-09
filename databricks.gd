@tool
class_name Databricks
extends Node


signal finished

enum Status {
	READY,
	IN_PROGRESS,
	SUCCESS,
	ERROR,
	CANCELLED,
}

const COLOR_IN_PROGRESS: = Color(0.5294118, 0.80784315, 0.92156863, 1)
const COLOR_SUCCESS: = Color(0.5647059, 0.93333334, 0.5647059, 1)
const COLOR_ERROR: = Color(0.8039216, 0.36078432, 0.36078432, 1)
const COLOR_CANCELLED: = Color(0.804, 0.361, 0.118, 1.0)
const STATUS_TO_COLOR_MAP: Dictionary [Status, Color] = {
	Status.READY: COLOR_SUCCESS,
	Status.IN_PROGRESS: COLOR_IN_PROGRESS,
	Status.SUCCESS: COLOR_SUCCESS,
	Status.ERROR: COLOR_ERROR,
	Status.CANCELLED: COLOR_CANCELLED,
}

const API_KEY_SETTING_PATH: String = "databricks/api_key"
const DEPLOYMENT_NAME_SETTING_PATH: String = "databricks/deployment_name"
const WAREHOUSE_ID_SETTING_PATH: String = "databricks/warehouse_id"


@onready var http: = HTTPRequest.new()


@export var api_key: LineEdit
@export var show_api_key: Button
@export var sql_statement: TextEdit
@export var result: Tree
@export var run: Button
@export var stop: Button
@export var status: RichTextLabel
@export var deployment_name: LineEdit
@export var warehouse_id: LineEdit

@export var hide_icon: CompressedTexture2D
@export var show_icon: CompressedTexture2D


var _last_request_ms: int


func initialize() -> void:
	add_child(http)
	_get_settings()
	_switch_buttons(true)
	_set_status(Status.READY)
	
	api_key.text_changed.connect(_save_settings.unbind(1))
	deployment_name.text_changed.connect(_save_settings.unbind(1))
	warehouse_id.text_changed.connect(_save_settings.unbind(1))
	show_api_key.pressed.connect(_on_show_api_key_pressed)
	stop.pressed.connect(_cancel_request)
	run.pressed.connect(_create_request)


func _get_settings() -> void:
	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
	if editor_settings.has_setting(API_KEY_SETTING_PATH):
		api_key.text = editor_settings.get_setting(API_KEY_SETTING_PATH)
	if editor_settings.has_setting(DEPLOYMENT_NAME_SETTING_PATH):
		deployment_name.text = editor_settings.get_setting(DEPLOYMENT_NAME_SETTING_PATH)
	if editor_settings.has_setting(WAREHOUSE_ID_SETTING_PATH):
		warehouse_id.text = editor_settings.get_setting(WAREHOUSE_ID_SETTING_PATH)

func _save_settings() -> void:
	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
	editor_settings.set_setting(API_KEY_SETTING_PATH, api_key.text)
	editor_settings.set_setting(DEPLOYMENT_NAME_SETTING_PATH, deployment_name.text)
	editor_settings.set_setting(WAREHOUSE_ID_SETTING_PATH, warehouse_id.text)


func _on_show_api_key_pressed() -> void:
	api_key.secret = not api_key.secret
	show_api_key.icon = show_icon if api_key.secret else hide_icon


func _create_request() -> void:
	_set_status(Status.IN_PROGRESS, "awaiting response.")
	_switch_buttons(false)
	result.clear()
	result.columns = 1
	result.set_column_title(0, "")
	
	var endpoint: String = "/api/2.0/sql/statements"
	var method: HTTPClient.Method = HTTPClient.METHOD_POST
	
	var url: String = "https://%s.cloud.databricks.com%s" % [deployment_name.text, endpoint]
	
	var params: Dictionary = {}
	
	var headers: Dictionary
	headers.authorization = " Bearer %s" % api_key.text
	
	var payload: Dictionary = {}
	payload.warehouse_id = warehouse_id.text
	payload.statement = sql_statement.text
	
	_send_request(
		url,
		params,
		headers,
		method,
		payload,
		_on_request_completed,
	)


func _on_request_completed(response_result: int, response_code: int, response_headers: PackedStringArray, response_body: PackedByteArray) -> void:
	_switch_buttons(true)
	finished.emit()
	
	if not _check_response_code(response_code):
		return
	
	var body_string: = response_body.get_string_from_utf8()
	
	var json := JSON.new()
	var parse_result := json.parse(body_string)
	
	var body_dict: Dictionary = {}
	if parse_result == OK:
		body_dict = json.get_data()
	else:
		_set_status(Status.ERROR, "Incorrect response format.", true)
		return
	
	#print(body_dict)
	if \
			not body_dict.has("result") \
			or not body_dict.result.has("data_array") \
			or not body_dict.has("manifest") \
			or not body_dict.manifest.has("schema") \
			or not body_dict.manifest.schema.has("columns"):
		_set_status(Status.ERROR, "Incorrect response format.", true)
		return
	
	_create_tree(body_dict.manifest.schema.columns, body_dict.result.data_array)
	_set_status(Status.SUCCESS, "", true)


func _check_response_code(response_code: HTTPClient.ResponseCode) -> bool:
	if response_code == HTTPClient.RESPONSE_UNAUTHORIZED:
		_set_status(Status.ERROR, "code: %s. Unauthorized - check API key." % response_code, true)
		return false
	elif response_code != HTTPClient.RESPONSE_OK:
		_set_status(Status.ERROR, "code: %s." % response_code, true)
		return false
	return true


func _send_request(url: String, params: Dictionary, headers: Dictionary, method: HTTPClient.Method, payload: Dictionary, callback: Callable) -> void:
	_last_request_ms = Time.get_ticks_msec()
	http.request_completed.connect(callback, CONNECT_ONE_SHOT)
	var error = http.request(url + _get_params_string(params), _get_headers_array(headers), method, JSON.stringify(payload) if payload else "")
	if error != OK:
		_set_status(Status.ERROR, "An error occurred in the HTTP request.")
		_switch_buttons(true)


func _get_headers_array(headers_dict: Dictionary) -> PackedStringArray:
	var headers_array: PackedStringArray = []
	for header in headers_dict.keys():
		headers_array.append("%s: %s" % [header, headers_dict[header]])
	return headers_array


func _get_params_string(params_dict: Dictionary) -> String:
	var params_string: String = ""
	for key in params_dict.keys():
		if params_string != "":
			params_string += "&"
		params_string += key + "=" + params_dict[key].uri_encode()
	if params_string:
		params_string = "?" + params_string
	return params_string


func _set_status(status_: Status, status_text: String = "", include_time: bool = false) -> void:
	var status_color: String = STATUS_TO_COLOR_MAP[status_].to_html()
	var status_name: String = Status.keys()[status_].capitalize()
	if include_time:
		status_name += " (%sms)" % (Time.get_ticks_msec() - _last_request_ms)
	if status_text:
		status_text = status_text.insert(0, ": ")
	status.text = "[color=%s]%s[/color]%s" % [status_color, status_name, status_text]


func _switch_buttons(on: bool) -> void:
	run.visible = on
	stop.visible = not on


func _cancel_request() -> void:
	_switch_buttons(true)
	_set_status(Status.CANCELLED)
	http.cancel_request()
	for connection in http.request_completed.get_connections():
		http.request_completed.disconnect(connection.callable)


func _create_tree(columns: Array, data: Array) -> void:
	result.create_item()
	result.columns = columns.size()
	
	for column_index in columns.size():
		result.set_column_title(column_index, columns[column_index].name)
		result.set_column_expand(column_index, false)
		if columns[column_index].name == "remarks":
			result.set_column_expand(column_index, true)
	
	for item_index in data.size():
		var item: TreeItem = result.create_item()
		for column_index in columns.size():
			item.set_text(column_index, data[item_index][column_index])
			item.set_text_overrun_behavior(column_index, TextServer.OVERRUN_NO_TRIMMING)
			item.set_editable(column_index, true)


func sql(sql_statement_: String, deployment_name_: String, warehouse_id_: String, api_key_: String) -> void:
	_create_request()
	#TODO finish
