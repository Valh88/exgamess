-- Фикстура: init возвращает функцию — validate_doc обязан отказать.
M = {}

function M.init(_args)
  return function() end
end
